package io.github.psychonaut0.reps.capture

import java.io.File
import java.io.IOException
import java.io.RandomAccessFile
import java.nio.channels.FileChannel
import java.nio.channels.FileLock
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/** A gate answer: a stable [code] plus the fields that code carries. */
data class GateResult(
    val code: String,
    val ticket: String? = null,
    val generation: Long? = null,
    val tickets: Int? = null,
    val interrupted: Int? = null,
) {
    fun toMap(): Map<String, Any> = buildMap {
        put("code", code)
        ticket?.let { put("ticket", it) }
        generation?.let { put("generation", it) }
        tickets?.let { put("tickets", it) }
        interrupted?.let { put("interrupted", it) }
    }
}

/**
 * Process-wide source-write gate shared by every Flutter engine (foreground
 * and background) of the process, per caller-provided state directory.
 *
 * - [mutex] guards this process's ticket table.
 * - `admission.lock` is locked exclusively (FileChannel lock) for every
 *   admission decision; the durable record `gate.state` is read and written
 *   only under it.
 * - `tickets.lock` is locked shared while this process has admitted tickets
 *   and exclusively by the process holding a capture.
 * - A `preparing`/`held` record keeps admission closed across process loss
 *   until an explicit release for the same capture and generation.
 * - While this process has tickets it keeps a durable, locked marker in
 *   `inflight/`; a marker whose lock is free belongs to a process that died
 *   with work in flight, so `drain` answers `recovery_required` until
 *   [acknowledgeInterrupted] (an explicit recovery decision) removes it.
 *
 * FileChannel locks are POSIX record locks owned by the process, and closing
 * any channel of a file drops them all, so each lock file has exactly one
 * long-lived channel per process and locks are released, never closed.
 */
object SourceGate {
    private val mutex = ReentrantLock()
    private val dirs = HashMap<String, GateDir>()
    private var counter = 0L

    private class TicketRef(var refs: Int, val generation: Long)

    private val nonce = java.util.UUID.randomUUID().toString().replace("-", "").take(16)

    private class GateDir(val path: File) {
        var markerFile: File? = null
        var markerChannel: FileChannel? = null
        var markerLock: FileLock? = null
        val admission: FileChannel = RandomAccessFile(File(path, "admission.lock"), "rw").channel
        val ticketsChannel: FileChannel = RandomAccessFile(File(path, "tickets.lock"), "rw").channel
        var shared: FileLock? = null
        var hold: FileLock? = null
        val tickets = HashMap<String, TicketRef>()
    }

    private data class Record(
        val generation: Long = 0,
        val state: String = "open",
        val capture: String = "",
        val decision: String = "",
    )

    private class Refusal(val code: String) : Exception(code)

    private const val HEADER = "reps-capture-gate/1"
    private val token = Regex("^[A-Za-z0-9._:-]{1,128}$")

    private fun gate(dir: String?): Pair<File, GateDir> {
        if (dir.isNullOrEmpty()) throw Refusal("invalid_argument")
        val canonical = File(dir).canonicalFile
        if (!canonical.isDirectory) throw Refusal("invalid_argument")
        val g = dirs.getOrPut(canonical.path) { GateDir(canonical) }
        return canonical to g
    }

    private fun <T> underAdmission(g: GateDir, block: () -> T): T {
        val deadline = System.nanoTime() + 2_000_000_000L
        var lock: FileLock? = null
        while (lock == null) {
            lock = try {
                g.admission.tryLock()
            } catch (e: IOException) {
                throw Refusal("io_error")
            } catch (e: UnsupportedOperationException) {
                throw Refusal("unsupported")
            }
            if (lock == null) {
                if (System.nanoTime() > deadline) throw Refusal("busy")
                Thread.sleep(2)
            }
        }
        try {
            return block()
        } finally {
            lock.release()
        }
    }

    private fun read(dir: File): Record {
        val file = File(dir, "gate.state")
        if (!file.exists()) return Record()
        val text = try {
            file.readText()
        } catch (e: IOException) {
            throw Refusal("io_error")
        }
        if (!text.endsWith("\n")) throw Refusal("state_corrupt")
        val lines = text.dropLast(1).split("\n")
        val keys = listOf("generation=", "state=", "capture=", "decision=")
        if (lines.size != 5 || lines[0] != HEADER) throw Refusal("state_corrupt")
        val values = keys.mapIndexed { i, key ->
            val line = lines[i + 1]
            if (!line.startsWith(key)) throw Refusal("state_corrupt")
            line.substring(key.length)
        }
        val generation = values[0].takeIf { it.matches(Regex("^[0-9]{1,18}$")) }?.toLong()
            ?: throw Refusal("state_corrupt")
        val record = Record(generation, values[1], values[2], values[3])
        val open = record.state == "open"
        if (!open && record.state != "preparing" && record.state != "held") throw Refusal("state_corrupt")
        if (open != record.capture.isEmpty()) throw Refusal("state_corrupt")
        if (record.capture.isNotEmpty() && !token.matches(record.capture)) throw Refusal("state_corrupt")
        if (record.decision.isNotEmpty() && !token.matches(record.decision)) throw Refusal("state_corrupt")
        return record
    }

    private fun write(dir: File, record: Record) {
        val text = "$HEADER\ngeneration=${record.generation}\nstate=${record.state}\n" +
            "capture=${record.capture}\ndecision=${record.decision}\n"
        val code = CaptureFiles.durableReplace(File(dir, "gate.state").path, text.toByteArray())
        if (code != "ok") throw Refusal(code)
    }

    private fun ensureShared(g: GateDir) {
        if (g.shared != null) return
        g.shared = try {
            g.ticketsChannel.tryLock(0L, Long.MAX_VALUE, true)
        } catch (e: IOException) {
            throw Refusal("io_error")
        } ?: throw Refusal("admission_closed") // another process holds a capture
    }

    private fun ensureMarker(g: GateDir) {
        if (g.markerLock != null) return
        val inflight = File(g.path, "inflight")
        if (!inflight.isDirectory) {
            if (!inflight.mkdir() || !CaptureFiles.syncDir(g.path)) throw Refusal("io_error")
        }
        val file = File(inflight, "${android.os.Process.myPid()}-$nonce.marker")
        val channel = RandomAccessFile(file, "rw").channel
        val lock = try {
            channel.tryLock()
        } catch (e: IOException) {
            null
        }
        if (lock == null) {
            channel.close()
            throw Refusal("io_error")
        }
        try {
            channel.force(true)
            if (!CaptureFiles.syncDir(inflight)) throw IOException("dir sync")
        } catch (e: IOException) {
            file.delete()
            lock.release()
            channel.close()
            throw Refusal("io_error")
        }
        g.markerFile = file
        g.markerChannel = channel
        g.markerLock = lock
    }

    /** Removes the (still locked) marker, then drops the shared ticket lock. */
    private fun releaseSharedIfIdle(g: GateDir) {
        if (g.tickets.isNotEmpty()) return
        g.markerFile?.let { file ->
            file.delete()
            file.parentFile?.let { CaptureFiles.syncDir(it) }
            g.markerLock?.release()
            g.markerChannel?.close()
        }
        g.markerFile = null
        g.markerChannel = null
        g.markerLock = null
        g.shared?.release()
        g.shared = null
    }

    /** "ok", "pending" (a live owner) or "recovery_required" with the count. */
    private fun scanMarkers(g: GateDir, remove: Boolean): Pair<String, Int> {
        val inflight = File(g.path, "inflight")
        val markers = inflight.listFiles { f -> f.name.endsWith(".marker") } ?: return "ok" to 0
        var orphans = 0
        var live = false
        for (marker in markers) {
            if (marker == g.markerFile) continue
            if (!marker.exists()) continue
            RandomAccessFile(marker, "rw").channel.use { channel ->
                val lock = try {
                    channel.tryLock()
                } catch (e: IOException) {
                    throw Refusal("io_error")
                }
                if (lock == null) {
                    live = true
                } else {
                    orphans++
                    if (remove) marker.delete()
                    lock.release()
                }
            }
        }
        if (remove && orphans > 0 && !CaptureFiles.syncDir(inflight)) throw Refusal("io_error")
        return when {
            live -> "pending" to orphans
            orphans > 0 -> "recovery_required" to orphans
            else -> "ok" to 0
        }
    }

    private fun newTicket(g: GateDir, generation: Long): GateResult {
        val id = "${android.os.Process.myPid()}-${++counter}"
        g.tickets[id] = TicketRef(1, generation)
        return GateResult("ok", ticket = id, generation = generation)
    }

    private fun matches(r: Record, capture: String?, generation: Long?) =
        r.state != "open" && r.capture == capture && r.generation == generation

    private fun guarded(block: () -> GateResult): GateResult = mutex.withLock {
        try {
            block()
        } catch (r: Refusal) {
            GateResult(r.code)
        } catch (e: IOException) {
            GateResult("io_error")
        }
    }

    fun admit(dir: String?, parent: String?): GateResult = guarded {
        val (path, g) = gate(dir)
        if (!parent.isNullOrEmpty()) {
            val t = g.tickets[parent] ?: throw Refusal("parent_completed")
            t.refs++
            return@guarded GateResult("ok", ticket = parent, generation = t.generation)
        }
        underAdmission(g) {
            val record = read(path)
            if (record.state != "open") throw Refusal("admission_closed")
            try {
                ensureShared(g)
                ensureMarker(g)
            } catch (r: Refusal) {
                releaseSharedIfIdle(g)
                throw r
            }
            newTicket(g, record.generation)
        }
    }

    fun complete(dir: String?, ticket: String?): GateResult = guarded {
        val (_, g) = gate(dir)
        val t = g.tickets[ticket] ?: throw Refusal("unknown_ticket")
        if (--t.refs == 0) g.tickets.remove(ticket)
        releaseSharedIfIdle(g)
        GateResult("ok")
    }

    fun prepare(dir: String?, capture: String?): GateResult = guarded {
        if (capture == null || !token.matches(capture)) throw Refusal("invalid_argument")
        val (path, g) = gate(dir)
        underAdmission(g) {
            val record = read(path)
            if (record.state != "open") throw Refusal("capture_in_progress")
            try {
                ensureShared(g)
                ensureMarker(g)
            } catch (r: Refusal) {
                releaseSharedIfIdle(g)
                throw r
            }
            val next = record.copy(generation = record.generation + 1, state = "preparing", capture = capture)
            try {
                write(path, next)
            } catch (r: Refusal) {
                releaseSharedIfIdle(g)
                throw r
            }
            newTicket(g, next.generation)
        }
    }

    fun drain(dir: String?, capture: String?, generation: Long?): GateResult = guarded {
        val (path, g) = gate(dir)
        underAdmission(g) {
            val record = read(path)
            if (!matches(record, capture, generation)) throw Refusal("mismatch")
            if (g.hold != null) return@underAdmission GateResult("held")
            if (g.tickets.isNotEmpty()) return@underAdmission GateResult("pending", tickets = g.tickets.size)
            val lock = try {
                g.ticketsChannel.tryLock(0L, Long.MAX_VALUE, false)
            } catch (e: IOException) {
                throw Refusal("io_error")
            } ?: return@underAdmission GateResult("pending") // another process has admitted work
            val (scan, orphans) = try {
                scanMarkers(g, remove = false)
            } catch (r: Refusal) {
                lock.release()
                throw r
            }
            if (scan != "ok") {
                lock.release()
                return@underAdmission GateResult(scan, interrupted = orphans.takeIf { it > 0 })
            }
            if (record.state == "preparing") {
                try {
                    write(path, record.copy(state = "held"))
                } catch (r: Refusal) {
                    lock.release()
                    throw r
                }
            }
            g.hold = lock
            GateResult("held")
        }
    }

    fun release(dir: String?, capture: String?, generation: Long?, decision: String?): GateResult = guarded {
        if (decision == null || !token.matches(decision)) throw Refusal("invalid_argument")
        val (path, g) = gate(dir)
        underAdmission(g) {
            val record = read(path)
            if (!matches(record, capture, generation)) throw Refusal("mismatch")
            write(path, record.copy(state = "open", capture = "", decision = decision))
            g.hold?.release()
            g.hold = null
            GateResult("ok")
        }
    }

    /** Explicit recovery decision; never called automatically. */
    fun acknowledgeInterrupted(dir: String?, decision: String?): GateResult = guarded {
        if (decision == null || !token.matches(decision)) throw Refusal("invalid_argument")
        val (_, g) = gate(dir)
        underAdmission(g) {
            val (_, orphans) = scanMarkers(g, remove = true)
            GateResult("ok", interrupted = orphans)
        }
    }

    fun verifyHold(dir: String?, capture: String?, generation: Long?): GateResult = guarded {
        val (path, g) = gate(dir)
        underAdmission(g) {
            val record = read(path)
            when {
                record.state == "open" -> GateResult("open")
                !matches(record, capture, generation) -> GateResult("mismatch")
                record.state == "preparing" -> GateResult("preparing")
                g.hold != null -> GateResult("held")
                else -> GateResult("recorded")
            }
        }
    }
}
