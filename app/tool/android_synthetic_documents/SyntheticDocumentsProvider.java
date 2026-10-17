package dev.animusstudio.alkion.synthetic.documents;

import android.database.Cursor;
import android.database.MatrixCursor;
import android.os.CancellationSignal;
import android.os.FileObserver;
import android.os.ParcelFileDescriptor;
import android.provider.DocumentsContract;
import android.provider.DocumentsContract.Document;
import android.provider.DocumentsContract.Root;
import android.provider.DocumentsProvider;
import android.system.Os;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileNotFoundException;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.Arrays;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.TimeUnit;
import org.json.JSONArray;
import org.json.JSONObject;

/** Disposable, bounded SAF fault fixture. No network, activity, public control,
 * URI-to-path conversion, persisted grants or caller-supplied filesystem paths.
 * Owner setup: files/proof-runs/<32hex>-<dev|supported>/{control.json,input.alkionbackup}.
 * Owner evidence: each namespace receipts/ and outputs/. Up to 16 append-only
 * namespaces coexist; each pins immutable config/input. Process death is separate.
 */
public final class SyntheticDocumentsProvider extends DocumentsProvider {
    private static final int LIMIT = 8 * 1024 * 1024;
    private static final String MIME = "application/octet-stream";
    private static final String[] INPUTS = {"open-good", "open-denied", "open-error",
        "open-short", "open-over-limit", "open-corrupt"};
    private static final String[] OUTPUTS = {"save-good", "save-write-denied",
        "save-write-interrupted", "save-readback-denied", "save-readback-changed"};
    private static final String[] ROOT_COLUMNS = {Root.COLUMN_ROOT_ID, Root.COLUMN_DOCUMENT_ID,
        Root.COLUMN_TITLE, Root.COLUMN_FLAGS, Root.COLUMN_MIME_TYPES, Root.COLUMN_AVAILABLE_BYTES};
    private static final String[] DOC_COLUMNS = {Document.COLUMN_DOCUMENT_ID,
        Document.COLUMN_DISPLAY_NAME, Document.COLUMN_MIME_TYPE, Document.COLUMN_FLAGS,
        Document.COLUMN_SIZE};
    private final ThreadPoolExecutor workers = new ThreadPoolExecutor(2, 2, 0,
        TimeUnit.MILLISECONDS, new ArrayBlockingQueue<Runnable>(4));
    private final Map<String, Output> outputs = new ConcurrentHashMap<>();
    private final Map<String, JSONArray> events = new ConcurrentHashMap<>();
    private final Map<String, Fixture> fixtures = new ConcurrentHashMap<>();
    private FileObserver rootsObserver;

    private static final class Fixture {
        final String namespace, run, variant, sha;
        final byte[] bytes;
        Fixture(String namespace, String run, String variant, String sha, byte[] bytes) {
            this.namespace = namespace; this.run = run; this.variant = variant; this.sha = sha; this.bytes = bytes;
        }
    }
    private static final class Output {
        final String namespace, id, scenario;
        final File file;
        final CountDownLatch closed = new CountDownLatch(1);
        volatile boolean complete;
        boolean opened;
        Output(String namespace, String id, String scenario, File file) {
            this.namespace = namespace; this.id = id; this.scenario = scenario; this.file = file;
        }
    }

    @Override public boolean onCreate() { return true; }

    private synchronized void watchRoots(File directory) {
        if (rootsObserver != null) return;
        // One fixed parent watcher invalidates DocumentsUI's cached roots when
        // owner setup atomically publishes another complete immutable namespace.
        // Invalid/incomplete directories never cause a readiness notification.
        rootsObserver = new FileObserver(directory, FileObserver.CREATE | FileObserver.MOVED_TO) {
            @Override public void onEvent(int event, String relative) {
                if (relative == null || !relative.matches("[a-f0-9]{32}-(dev|supported)")) return;
                try {
                    load(relative);
                    getContext().getContentResolver().notifyChange(DocumentsContract.buildRootsUri(
                        "dev.animusstudio.alkion.synthetic.documents.provider"), null);
                } catch (FileNotFoundException incomplete) { /* Never announce an invalid namespace. */ }
            }
        };
        rootsObserver.startWatching();
    }

    @Override public synchronized void shutdown() {
        if (rootsObserver != null) { rootsObserver.stopWatching(); rootsObserver = null; }
        workers.shutdownNow();
        super.shutdown();
    }

    private File owned(String relative) throws IOException {
        if (!relative.matches("[a-z0-9./-]+") || relative.contains("..") || relative.startsWith("/")) {
            throw new IOException("Invalid fixed fixture path");
        }
        // Resolve only Android's OS-owned parent alias, never an owned link.
        File lexical = new File(getContext().getApplicationInfo().dataDir);
        File application = new File(lexical.getParentFile().getCanonicalFile(), lexical.getName());
        File root = new File(application, "files");
        if (!lexical.getName().equals("dev.animusstudio.alkion.synthetic.documents") ||
            !application.getAbsolutePath().equals(application.getCanonicalPath()) ||
            !application.isDirectory() || !root.isDirectory()) throw new IOException("Owned root invalid");
        File file = new File(root, relative);
        if (!file.getAbsolutePath().equals(file.getCanonicalPath()) ||
            !root.getAbsolutePath().equals(root.getCanonicalPath())) {
            throw new IOException("Linked fixture path");
        }
        return file;
    }
    private static byte[] bounded(File file, int bound) throws IOException {
        if (!file.isFile() || file.length() < 1 || file.length() > bound) {
            throw new IOException("Fixture file bound");
        }
        try (FileInputStream input = new FileInputStream(file);
             ByteArrayOutputStream result = new ByteArrayOutputStream()) {
            byte[] buffer = new byte[8192];
            int count;
            while ((count = input.read(buffer)) != -1) {
                if (result.size() + count > bound) throw new IOException("Fixture stream bound");
                result.write(buffer, 0, count);
            }
            return result.toByteArray();
        }
    }
    private static void privateMode(File file, int mode) throws IOException {
        try { Os.chmod(file.getPath(), mode); }
        catch (Exception error) { throw new IOException("Owner-only fixture mode", error); }
    }
    private static String sha(byte[] bytes) {
        try {
            StringBuilder text = new StringBuilder();
            for (byte item : MessageDigest.getInstance("SHA-256").digest(bytes)) {
                text.append(String.format(java.util.Locale.ROOT, "%02x", item & 255));
            }
            return text.toString();
        } catch (Exception error) { throw new IllegalStateException(error); }
    }
    private static String namespace(String documentId) throws FileNotFoundException {
        String name = documentId.split(":", 2)[0];
        if (!name.matches("[a-f0-9]{32}-(dev|supported)")) {
            throw new FileNotFoundException("Invalid fixed run/variant namespace");
        }
        return name;
    }
    private synchronized Fixture load(String name) throws FileNotFoundException {
        try {
            if (!namespace(name).equals(name)) throw new IOException("Namespace mismatch");
            String prefix = "proof-runs/" + name + "/";
            File directory = owned("proof-runs/" + name);
            File controlFile = owned(prefix + "control.json"), inputFile = owned(prefix + "input.alkionbackup");
            if (!directory.isDirectory() || (Os.stat(directory.getPath()).st_mode & 077) != 0 ||
                (Os.stat(controlFile.getPath()).st_mode & 077) != 0 ||
                (Os.stat(inputFile.getPath()).st_mode & 077) != 0) throw new IOException("Setup must be owner-only");
            JSONObject control = new JSONObject(new String(bounded(controlFile, 4096), StandardCharsets.UTF_8));
            String run = control.getString("run_id"), variant = control.getString("variant"), digest = control.getString("sha256");
            if (control.length() != 5 || !"alkion-synthetic-documents/1".equals(control.getString("format")) ||
                !run.matches("[a-f0-9]{32}") || !variant.matches("dev|supported") ||
                !name.equals(run + "-" + variant) || !digest.matches("[a-f0-9]{64}")) {
                throw new IOException("Unbound fixture control");
            }
            byte[] bytes = bounded(inputFile, LIMIT);
            if (control.getLong("length") != bytes.length || !sha(bytes).equals(digest)) throw new IOException("Changed input");
            // An exclusive durable pin prevents adopting a replacement after process restart.
            // Interrupted pins remain a visible failure; no cleanup/replacement fallback.
            byte[] pinBytes = (run + "\n" + variant + "\n" + bytes.length + "\n" + digest).getBytes(StandardCharsets.UTF_8);
            File pin = owned(prefix + "input.pin");
            if (pin.createNewFile()) {
                privateMode(pin, 0600);
                try (FileOutputStream output = new FileOutputStream(pin)) {
                    output.write(pinBytes); output.flush(); output.getFD().sync();
                }
            } else if (!Arrays.equals(bounded(pin, 4096), pinBytes)) throw new IOException("Immutable namespace pin changed");
            Fixture fixture = fixtures.get(name);
            if (fixture != null && !fixture.sha.equals(digest)) throw new IOException("Immutable namespace changed");
            if (fixture == null) {
                if (fixtures.size() >= 16) throw new IOException("Namespace bound");
                fixture = new Fixture(name, run, variant, digest, bytes);
                fixtures.put(name, fixture);
            }
            return fixture;
        } catch (Exception error) { throw missing("Fixture setup invalid", error); }
    }
    private static FileNotFoundException missing(String message, Exception cause) {
        FileNotFoundException error = new FileNotFoundException(message);
        error.initCause(cause);
        return error;
    }
    private String scenario(String id) throws FileNotFoundException {
        Fixture value = load(namespace(id));
        for (String name : INPUTS) if (id.equals(value.namespace + ":" + name)) return name;
        Output output = outputs.get(id);
        if (output != null && output.namespace.equals(value.namespace)) return output.scenario;
        throw new FileNotFoundException("Unknown run-bound synthetic document");
    }
    private MatrixCursor documents(String[] projection) {
        return new MatrixCursor(projection == null ? DOC_COLUMNS : projection);
    }
    private void row(MatrixCursor cursor, String id, String name, boolean directory, Long size) {
        MatrixCursor.RowBuilder row = cursor.newRow();
        for (String column : cursor.getColumnNames()) {
            Object value = null;
            if (column.equals(Document.COLUMN_DOCUMENT_ID)) value = id;
            else if (column.equals(Document.COLUMN_DISPLAY_NAME)) value = name;
            else if (column.equals(Document.COLUMN_MIME_TYPE)) value = directory ? Document.MIME_TYPE_DIR : MIME;
            else if (column.equals(Document.COLUMN_FLAGS)) value = directory ? Document.FLAG_DIR_SUPPORTS_CREATE
                : outputs.containsKey(id) ? Document.FLAG_SUPPORTS_WRITE : 0;
            else if (column.equals(Document.COLUMN_SIZE)) value = size;
            row.add(column, value);
        }
    }
    @Override public Cursor queryRoots(String[] projection) {
        MatrixCursor cursor = new MatrixCursor(projection == null ? ROOT_COLUMNS : projection);
        File[] directories;
        try {
            File parent = owned("proof-runs");
            if (!parent.isDirectory() || (Os.stat(parent.getPath()).st_mode & 077) != 0) return cursor;
            watchRoots(parent);
            directories = parent.listFiles((directory, name) -> name.matches("[a-f0-9]{32}-(dev|supported)"));
        } catch (Exception absent) { return cursor; }
        if (directories == null || directories.length > 16) return cursor;
        Arrays.sort(directories, (first, second) -> first.getName().compareTo(second.getName()));
        for (File directory : directories) {
            Fixture value;
            try { value = load(directory.getName()); } catch (FileNotFoundException invalid) { continue; }
            MatrixCursor.RowBuilder row = cursor.newRow();
            for (String column : cursor.getColumnNames()) {
                Object entry = null;
                if (column.equals(Root.COLUMN_ROOT_ID)) entry = value.namespace;
                else if (column.equals(Root.COLUMN_DOCUMENT_ID)) entry = value.namespace + ":root";
                else if (column.equals(Root.COLUMN_TITLE)) entry = "Alkion synthetic " + value.namespace;
                else if (column.equals(Root.COLUMN_FLAGS)) entry = Root.FLAG_SUPPORTS_CREATE | Root.FLAG_LOCAL_ONLY;
                else if (column.equals(Root.COLUMN_MIME_TYPES)) entry = MIME;
                else if (column.equals(Root.COLUMN_AVAILABLE_BYTES)) entry = LIMIT * 8L;
                row.add(column, entry);
            }
        }
        return cursor;
    }
    @Override public Cursor queryDocument(String id, String[] projection) throws FileNotFoundException {
        Fixture value = load(namespace(id));
        MatrixCursor cursor = documents(projection);
        if (id.equals(value.namespace + ":root")) row(cursor, id, "Alkion synthetic " + value.namespace, true, null);
        else {
            String name = scenario(id);
            row(cursor, id, value.namespace + "-" + name + ".alkionbackup", false,
                name.equals("open-short") ? (long) value.bytes.length : null);
        }
        return cursor;
    }
    @Override public Cursor queryChildDocuments(String parent, String[] projection, String sortOrder)
        throws FileNotFoundException {
        Fixture value = load(namespace(parent));
        if (!parent.equals(value.namespace + ":root")) throw new FileNotFoundException("Not the synthetic root");
        MatrixCursor cursor = documents(projection);
        for (String name : INPUTS) row(cursor, value.namespace + ":" + name,
            value.namespace + "-" + name + ".alkionbackup", false,
            name.equals("open-short") ? (long) value.bytes.length : null);
        for (Output output : outputs.values()) if (output.namespace.equals(value.namespace)) row(cursor, output.id,
            value.namespace + "-" + output.scenario + ".alkionbackup", false, null);
        return cursor;
    }
    @Override public boolean isChildDocument(String parent, String id) {
        try { scenario(id); return namespace(parent).equals(namespace(id)) && parent.equals(namespace(id) + ":root"); }
        catch (FileNotFoundException invalid) { return false; }
    }
    @Override public synchronized String createDocument(String parent, String mime, String displayName)
        throws FileNotFoundException {
        Fixture value = load(namespace(parent));
        if (!parent.equals(value.namespace + ":root") || !MIME.equals(mime)) throw new FileNotFoundException("Invalid create");
        String name = null;
        for (String candidate : OUTPUTS) {
            if (displayName.equals(value.namespace + "-" + candidate + ".alkionbackup")) name = candidate;
        }
        if (name == null) throw new FileNotFoundException("Unexpected proof filename");
        for (Output old : outputs.values()) if (old.namespace.equals(value.namespace) && old.scenario.equals(name)) {
            throw new FileNotFoundException("Refuse replacement of a prior attempt");
        }
        try {
            String prefix = "proof-runs/" + value.namespace + "/outputs/";
            File directory = owned("proof-runs/" + value.namespace + "/outputs");
            if (!directory.isDirectory() && !directory.mkdir()) throw new IOException("Create outputs");
            privateMode(directory, 0700);
            File[] prior = directory.listFiles();
            if (prior == null) throw new IOException("Read outputs");
            for (File old : prior) if (old.getName().startsWith(name + "-")) throw new IOException("Prior output retained");
            String unique = UUID.randomUUID().toString();
            String id = value.namespace + ":out:" + name + ":" + unique;
            File file = owned(prefix + name + "-" + unique + ".partial");
            if (!file.createNewFile()) throw new IOException("Output collision");
            privateMode(file, 0600);
            outputs.put(id, new Output(value.namespace, id, name, file));
            event(value.namespace, name, "create", "created", 0, sha(new byte[0]), null);
            return id;
        } catch (IOException error) { throw missing("Create failed", error); }
    }
    @Override public void deleteDocument(String id) throws FileNotFoundException {
        event(namespace(id), scenario(id), "delete", "refused", 0, null, "unexpected_delete");
        throw new FileNotFoundException("Failed publications are never deleted by this fixture");
    }
    @Override public ParcelFileDescriptor openDocument(String id, String mode, CancellationSignal signal)
        throws FileNotFoundException {
        if (signal != null) signal.throwIfCanceled();
        String scope = namespace(id);
        String name = scenario(id);
        Output output = outputs.get(id);
        if (mode.equals("r")) {
            if (name.equals("open-denied") || name.equals("save-readback-denied")) {
                event(scope, name, "read", "denied", 0, null, "security_exception");
                throw new SecurityException("Synthetic read grant refusal");
            }
            byte[] bytes;
            if (output == null) bytes = load(scope).bytes.clone();
            else {
                try {
                    if (!output.closed.await(15, TimeUnit.SECONDS) || !output.complete) {
                        throw new IOException("Provider write incomplete");
                    }
                    bytes = bounded(output.file, LIMIT);
                } catch (Exception error) { throw missing("Readback failed", error); }
            }
            if (name.equals("open-corrupt") || name.equals("save-readback-changed")) bytes[bytes.length - 1] ^= 1;
            if (name.equals("open-short")) bytes = Arrays.copyOf(bytes, bytes.length - 1);
            return readPipe(scope, name, bytes, name.equals("open-error"));
        }
        if (!mode.equals("w") || output == null) throw new FileNotFoundException("Only r/w proof streams supported");
        synchronized (output) {
            if (output.opened) throw new FileNotFoundException("Refuse repeated output writer");
            output.opened = true;
        }
        if (name.equals("save-write-denied")) {
            event(scope, name, "write", "denied", 0, null, "security_exception");
            output.closed.countDown();
            throw new SecurityException("Synthetic write grant refusal");
        }
        return writePipe(output);
    }
    private ParcelFileDescriptor readPipe(final String scope, final String name, final byte[] bytes, final boolean fail)
        throws FileNotFoundException {
        try {
            final ParcelFileDescriptor[] pipe = ParcelFileDescriptor.createReliablePipe();
            try { workers.execute(() -> {
                int length = fail ? Math.min(4096, bytes.length) : bytes.length;
                try (ParcelFileDescriptor.AutoCloseOutputStream stream =
                        new ParcelFileDescriptor.AutoCloseOutputStream(pipe[1])) {
                    stream.write(bytes, 0, length);
                    stream.flush();
                    if (fail) pipe[1].closeWithError("Synthetic interrupted input");
                    event(scope, name, "read", fail ? "interrupted" : "complete", length,
                        sha(Arrays.copyOf(bytes, length)), fail ? "close_with_error" : null);
                } catch (Exception error) {
                    closeError(pipe[1], "Synthetic read peer error");
                    event(scope, name, "read", "peer_error", length, null, error.getClass().getSimpleName());
                }
            }); } catch (RuntimeException rejected) {
                closeError(pipe[0], "Worker bound"); closeError(pipe[1], "Worker bound"); throw rejected;
            }
            return pipe[0];
        } catch (Exception error) { throw missing("Read pipe failed", error); }
    }
    private ParcelFileDescriptor writePipe(final Output output) throws FileNotFoundException {
        try {
            final ParcelFileDescriptor[] pipe = ParcelFileDescriptor.createReliablePipe();
            try { workers.execute(() -> {
                int length = 0;
                try (ParcelFileDescriptor.AutoCloseInputStream stream =
                        new ParcelFileDescriptor.AutoCloseInputStream(pipe[0]);
                     FileOutputStream retained = new FileOutputStream(output.file)) {
                    byte[] buffer = new byte[8192];
                    int count;
                    while ((count = stream.read(buffer)) != -1) {
                        if (output.scenario.equals("save-write-interrupted")) {
                            retained.write(buffer, 0, 1); length = 1;
                            retained.flush(); retained.getFD().sync();
                            pipe[0].closeWithError("Synthetic interrupted output");
                            event(output.namespace, output.scenario, "write", "interrupted", length, null, "close_with_error");
                            return;
                        }
                        length += count;
                        if (length > LIMIT) throw new IOException("Output bound");
                        retained.write(buffer, 0, count);
                    }
                    pipe[0].checkError();
                    retained.flush(); retained.getFD().sync();
                    output.complete = true;
                    event(output.namespace, output.scenario, "write", "complete", length,
                        sha(bounded(output.file, LIMIT)), null);
                } catch (Exception error) {
                    closeError(pipe[0], "Synthetic write failed");
                    event(output.namespace, output.scenario, "write", "peer_error", length, null, error.getClass().getSimpleName());
                } finally { output.closed.countDown(); }
            }); } catch (RuntimeException rejected) {
                closeError(pipe[0], "Worker bound"); closeError(pipe[1], "Worker bound"); throw rejected;
            }
            return pipe[1];
        } catch (Exception error) { throw missing("Write pipe failed", error); }
    }
    private static void closeError(ParcelFileDescriptor fd, String message) {
        try { fd.closeWithError(message); } catch (IOException alreadyClosed) { /* Peer already sees close. */ }
    }
    private synchronized void event(String scope, String name, String operation, String state, int length,
                                    String digest, String error) {
        try {
            Fixture value = load(scope);
            JSONArray trace = events.computeIfAbsent(scope + ":" + name, ignored -> new JSONArray());
            if (trace.length() >= 16) throw new IOException("Event bound");
            trace.put(new JSONObject().put("operation", operation).put("state", state)
                .put("length", length).put("sha256", digest == null ? JSONObject.NULL : digest)
                .put("error", error == null ? JSONObject.NULL : error).put("reliable_pipe",
                    !state.equals("denied") && (operation.equals("read") || operation.equals("write"))));
            JSONObject receipt = new JSONObject().put("format", "alkion-synthetic-document-receipt/1")
                .put("run_id", value.run).put("variant", value.variant).put("case", name).put("input_sha256", value.sha)
                .put("input_length", value.bytes.length).put("events", trace);
            for (Output output : outputs.values()) if (output.namespace.equals(scope) && output.scenario.equals(name)) {
                receipt.put("output_retained", output.file.isFile());
                receipt.put("output_length", output.file.length());
            }
            byte[] bytes = receipt.toString().getBytes(StandardCharsets.UTF_8);
            if (bytes.length > 16384) throw new IOException("Receipt bound");
            String prefix = "proof-runs/" + scope + "/receipts/";
            File directory = owned("proof-runs/" + scope + "/receipts");
            if (!directory.isDirectory() && !directory.mkdir()) throw new IOException("Create receipts");
            privateMode(directory, 0700);
            File partial = owned(prefix + name + ".partial");
            try (FileOutputStream stream = new FileOutputStream(partial)) {
                privateMode(partial, 0600);
                stream.write(bytes); stream.flush(); stream.getFD().sync();
            }
            if (!partial.renameTo(owned(prefix + name + ".json"))) {
                throw new IOException("Publish receipt");
            }
        } catch (Exception failure) { throw new IllegalStateException("Synthetic receipt failed", failure); }
    }
}
