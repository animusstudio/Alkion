package dev.animusstudio.alkion.synthetic.uiobserver;

import android.accessibilityservice.AccessibilityServiceInfo;
import android.app.Instrumentation;
import android.app.UiAutomation;
import android.content.Context;
import android.graphics.Point;
import android.graphics.Rect;
import android.hardware.display.DisplayManager;
import android.os.Bundle;
import android.os.Process;
import android.os.SystemClock;
import android.system.Os;
import android.system.OsConstants;
import android.util.Xml;
import android.view.Display;
import android.view.accessibility.AccessibilityNodeInfo;
import android.view.accessibility.AccessibilityWindowInfo;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.io.FileDescriptor;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.time.Instant;
import java.util.Arrays;
import java.util.HashSet;
import java.util.concurrent.atomic.AtomicBoolean;
import org.json.JSONArray;
import org.json.JSONObject;
import org.xmlpull.v1.XmlSerializer;

/** Disposable self-targeted observer. It never launches, dispatches or waits for idle. */
public final class HierarchyInstrumentation extends Instrumentation {
    private static final String PACKAGE = "dev.animusstudio.alkion.synthetic.uiobserver";
    private static final int LIMIT = 1024 * 1024;
    private static final HashSet<String> ROOTS = new HashSet<>(Arrays.asList(
        "com.android.systemui", "com.android.documentsui", "com.android.permissioncontroller",
        "dev.animusstudio.alkion.dev", "dev.animusstudio.alkion"));
    private final AtomicBoolean completed = new AtomicBoolean();
    private Bundle arguments;
    private File directory;
    private JSONObject receipt;
    private long started;
    private int nodes;
    private int visibleLabels;
    private Candidate candidate;
    private final JSONArray samples = new JSONArray();
    private final WindowAdmission admission = new WindowAdmission();

    /** The same finite controller is exercised on the host; it has no Android dependency. */
    static final class Polling {
        static final int MAX_SAMPLES = 40;
        static final long SAMPLE_BUDGET_MS = 5000;
        interface Clock { long now(); void pause(long milliseconds); }
        interface Probe { boolean sample(int index) throws Exception; }
        static final class IncompleteChild extends Exception {
            IncompleteChild() { super("incomplete_child"); }
        }

        static final class WindowAbsent extends Exception {
            WindowAbsent() { super("window_absent"); }
        }
        static final class WindowNotReady extends Exception {
            WindowNotReady() { super("window_not_ready"); }
        }

        static int run(Clock clock, Probe probe, long started) throws Exception {
            long deadline = started + SAMPLE_BUDGET_MS;
            for (int index = 1; index <= MAX_SAMPLES; index++) {
                if (clock.now() >= deadline) throw new IllegalStateException("readiness_deadline");
                boolean ready;
                try { ready = probe.sample(index); }
                catch (IncompleteChild | WindowAbsent | WindowNotReady rejected) { ready = false; }
                // A slow sample cannot authorize a result after the sampling deadline.
                if (clock.now() >= deadline) throw new IllegalStateException("readiness_deadline");
                if (ready) return index;
                if (index == MAX_SAMPLES) throw new IllegalStateException("readiness_sample_limit");
                long remaining = deadline - clock.now();
                if (remaining <= 0) throw new IllegalStateException("readiness_deadline");
                clock.pause(Math.min(100, remaining));
            }
            throw new IllegalStateException("readiness_sample_limit");
        }
    }

    /** Actual getter/classification controller, also compiled and exercised without Android objects. */
    static final class WindowAdmission {
        interface Source {
            String rootPackage() throws Exception;
            int nodeWindowId() throws Exception;
            boolean windowPresent() throws Exception;
            int windowId() throws Exception;
            int windowType() throws Exception;
            int displayId() throws Exception;
            boolean active() throws Exception;
            boolean focused() throws Exception;
        }
        interface Journal {
            void stage(String value) throws Exception;
            void fact(String key, Object value) throws Exception;
        }
        static final class Facts {
            String rootPackage;
            int nodeWindowId, windowId, windowType, displayId;
            boolean active, focused;
        }
        Integer pinnedId, pinnedType;
        private static void check(boolean value, String reason) {
            if (!value) throw new IllegalStateException(reason);
        }
        Facts read(Source source, String expected, Journal journal) throws Exception {
            Facts facts = new Facts();
            journal.stage("root_package"); facts.rootPackage = source.rootPackage();
            journal.fact("root_package", facts.rootPackage); journal.stage("root_package_check");
            check(expected.equals(facts.rootPackage), "root_package_changed");
            journal.stage("node_window_id"); facts.nodeWindowId = source.nodeWindowId();
            journal.fact("node_window_id", facts.nodeWindowId); journal.stage("node_window_id_check");
            check(facts.nodeWindowId >= 0, "node_window_id_invalid");
            check(pinnedId == null || pinnedId == facts.nodeWindowId, "sample_window_changed");
            pinnedId = facts.nodeWindowId;
            journal.stage("window_present"); boolean present = source.windowPresent();
            journal.fact("window_present", present);
            if (!present) { journal.stage("window_absent"); throw new Polling.WindowAbsent(); }
            journal.stage("window_id"); facts.windowId = source.windowId();
            journal.fact("window_id", facts.windowId); journal.stage("window_id_check");
            check(facts.windowId >= 0 && facts.windowId == facts.nodeWindowId, "window_id_mismatch");
            journal.stage("window_type"); facts.windowType = source.windowType();
            journal.fact("window_type", facts.windowType); journal.stage("window_type_check");
            check(facts.windowType == 1 || facts.windowType == 3, "window_type_invalid");
            check(pinnedType == null || pinnedType == facts.windowType, "sample_window_type_changed");
            pinnedType = facts.windowType;
            journal.stage("display_id"); facts.displayId = source.displayId();
            journal.fact("display_id", facts.displayId); journal.stage("display_id_check");
            check(facts.displayId == 0, "window_display_changed");
            journal.stage("window_active"); facts.active = source.active();
            journal.fact("window_active", facts.active);
            journal.stage("window_focused"); facts.focused = source.focused();
            journal.fact("window_focused", facts.focused);
            if (!facts.active || !facts.focused) {
                journal.stage("window_not_ready"); throw new Polling.WindowNotReady();
            }
            journal.stage("admitted");
            return facts;
        }
    }

    private static final class Candidate {
        final byte[] data;
        final JSONObject metadata;
        Candidate(byte[] data, JSONObject metadata) { this.data = data; this.metadata = metadata; }
    }

    @Override public void onCreate(Bundle args) { arguments = args; start(); }

    private void require(boolean value, String reason) {
        if (!value) throw new IllegalStateException(reason);
    }

    private String argument(String key, String pattern) {
        String value = arguments == null ? null : arguments.getString(key);
        require(value != null && value.matches(pattern), "invalid_" + key);
        return value;
    }

    @Override public void onStart() {
        started = SystemClock.elapsedRealtime();
        try {
            require(PACKAGE.equals(getTargetContext().getPackageName()), "self_target_required");
            String run = argument("run_id", "[a-f0-9]{32}");
            String source = argument("source_commit", "[a-f0-9]{40}");
            String request = argument("request_id", "[a-f0-9]{32}");
            String serial = argument("serial", "emulator-[0-9]{4,5}");
            String avd = argument("avd", "[A-Za-z0-9_.-]{1,80}");
            String expected = argument("expected_package", "[a-z0-9_.]{1,100}");
            boolean needsLabels = expected.equals("dev.animusstudio.alkion.dev")
                || expected.equals("dev.animusstudio.alkion");
            require(ROOTS.contains(expected), "unknown_expected_package");
            File root = getTargetContext().getFilesDir().getCanonicalFile();
            File parent = new File(new File(root, "observations"), run);
            require(parent.mkdirs() || parent.isDirectory(), "observation_parent_unavailable");
            require(parent.getCanonicalFile().equals(parent.getAbsoluteFile()), "linked_parent");
            directory = new File(parent, request);
            require(directory.mkdir(), "request_already_present");
            receipt = new JSONObject().put("format", "alkion-android-ui-observation/1")
                .put("diagnostic_schema", "alkion-ui-window-facts/1")
                .put("run_id", run).put("source_commit", source).put("request_id", request)
                .put("serial", serial).put("avd", avd).put("expected_package", expected)
                .put("readiness", needsLabels ? "visible-label" : "structural")
                .put("samples", samples).put("sample_count", 0)
                .put("observer_package", PACKAGE).put("observer_uid", Process.myUid())
                .put("observer_version", getTargetContext().getPackageManager()
                    .getPackageInfo(PACKAGE, 0).getLongVersionCode());
            Thread watchdog = new Thread(() -> {
                SystemClock.sleep(8000);
                complete(false, "observer_deadline");
            }, "bounded-observation");
            watchdog.setDaemon(true); watchdog.start();
            UiAutomation automation = getUiAutomation(UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES);
            require(automation != null, "automation_unavailable");
            AccessibilityServiceInfo info = automation.getServiceInfo();
            require(info != null, "automation_service_unavailable");
            info.flags |= AccessibilityServiceInfo.FLAG_REPORT_VIEW_IDS
                | AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS
                | AccessibilityServiceInfo.FLAG_INCLUDE_NOT_IMPORTANT_VIEWS;
            automation.setServiceInfo(info);
            Polling.run(new Polling.Clock() {
                public long now() { return SystemClock.elapsedRealtime(); }
                public void pause(long milliseconds) { SystemClock.sleep(milliseconds); }
            }, index -> sample(automation, expected, needsLabels, index), started);
            checkTime();
            complete(true, null);
        } catch (Exception failure) { complete(false, failure.toString()); }
    }

    private synchronized void stage(JSONObject summary, String value) throws Exception {
        summary.put("stage", value).put("elapsed_ms", SystemClock.elapsedRealtime() - started);
    }
    private synchronized void fact(JSONObject summary, String key, Object value) throws Exception {
        summary.put(key, value == null ? JSONObject.NULL : value);
        summary.getJSONArray("observed").put(key);
        summary.put("elapsed_ms", SystemClock.elapsedRealtime() - started);
    }

    private boolean sample(UiAutomation automation, String expected, boolean needsLabels, int index)
            throws Exception {
        checkTime();
        JSONObject summary = new JSONObject().put("index", index).put("stage", "init")
            .put("observed", new JSONArray()).put("elapsed_ms", SystemClock.elapsedRealtime() - started)
            .put("candidate_complete", false).put("outcome", "pending").put("ready", false)
            .put("node_count", 0).put("visible_label_count", 0).put("xml_length", 0).put("xml_sha256", "")
            .put("exception", JSONObject.NULL).put("exception_class", JSONObject.NULL);
        for (String key : Arrays.asList("cache_cleared", "root_available", "root_package", "node_window_id",
                "window_present", "window_id", "window_type", "display_id", "window_active", "window_focused")) {
            summary.put(key, JSONObject.NULL);
        }
        synchronized (this) {
            require(!completed.get(), "capture_deadline");
            samples.put(summary); receipt.put("sample_count", samples.length());
        }
        AccessibilityNodeInfo node = null;
        final AccessibilityWindowInfo[] heldWindow = {null};
        try {
            stage(summary, "cache_cleared");
            // API36 returns false when this connection has no cache; failures throw.
            fact(summary, "cache_cleared", automation.clearCache());
            stage(summary, "root_available"); node = automation.getRootInActiveWindow();
            fact(summary, "root_available", node != null); checkTime();
            if (node == null) {
                stage(summary, "null_root");
                synchronized (this) { summary.put("outcome", "null_root"); }
                return false;
            }
            final AccessibilityNodeInfo rootNode = node;
            WindowAdmission.Facts facts = admission.read(new WindowAdmission.Source() {
                public String rootPackage() { CharSequence value = rootNode.getPackageName(); return value == null ? null : value.toString(); }
                public int nodeWindowId() { return rootNode.getWindowId(); }
                public boolean windowPresent() { heldWindow[0] = rootNode.getWindow(); return heldWindow[0] != null; }
                public int windowId() { return heldWindow[0].getId(); }
                public int windowType() { return heldWindow[0].getType(); }
                public int displayId() { return heldWindow[0].getDisplayId(); }
                public boolean active() { return heldWindow[0].isActive(); }
                public boolean focused() { return heldWindow[0].isFocused(); }
            }, expected, new WindowAdmission.Journal() {
                public void stage(String value) throws Exception { HierarchyInstrumentation.this.stage(summary, value); }
                public void fact(String key, Object value) throws Exception { HierarchyInstrumentation.this.fact(summary, key, value); }
            });
            stage(summary, "display_geometry");
            Display display = ((DisplayManager) getTargetContext().getSystemService(Context.DISPLAY_SERVICE)).getDisplay(0);
            require(display != null, "display_unavailable");
            Point size = new Point(); display.getRealSize(size); int rotation = display.getRotation();
            stage(summary, "serialize"); nodes = 0; visibleLabels = 0;
            ByteArrayOutputStream bytes = new ByteArrayOutputStream();
            XmlSerializer xml = Xml.newSerializer(); xml.setOutput(bytes, "UTF-8");
            xml.startDocument("UTF-8", true); xml.startTag(null, "hierarchy");
            xml.attribute(null, "rotation", Integer.toString(rotation));
            serialize(xml, bytes, node, 0, facts.nodeWindowId, expected, facts.rootPackage, facts.nodeWindowId);
            xml.endTag(null, "hierarchy"); xml.endDocument(); xml.flush();
            require(bytes.size() > 0 && bytes.size() <= LIMIT, "xml_size_limit");
            byte[] data = bytes.toByteArray();
            String hash = hex(MessageDigest.getInstance("SHA-256").digest(data));
            boolean ready = !needsLabels || visibleLabels > 0;
            JSONObject metadata = new JSONObject().put("root_package", facts.rootPackage)
                .put("window_id", facts.windowId).put("window_type", facts.windowType)
                .put("window_active", facts.active).put("window_focused", facts.focused)
                .put("display_id", facts.displayId).put("rotation", rotation).put("width", size.x).put("height", size.y)
                .put("node_count", nodes).put("visible_label_count", visibleLabels)
                .put("xml_length", data.length).put("xml_sha256", hash).put("candidate_sample", index);
            synchronized (this) {
                require(!completed.get(), "capture_deadline");
                candidate = new Candidate(data, metadata);
                summary.put("candidate_complete", true).put("outcome", ready ? "complete" : "content_not_ready")
                    .put("ready", ready).put("node_count", nodes).put("visible_label_count", visibleLabels)
                    .put("xml_length", data.length).put("xml_sha256", hash);
                stage(summary, ready ? "complete" : "content_not_ready");
            }
            return ready;
        } catch (Polling.IncompleteChild | Polling.WindowAbsent | Polling.WindowNotReady rejected) {
            nodes = 0; visibleLabels = 0;
            String outcome = rejected instanceof Polling.IncompleteChild ? "incomplete_child"
                : rejected instanceof Polling.WindowAbsent ? "window_absent" : "window_not_ready";
            synchronized (this) { summary.put("outcome", outcome); stage(summary, outcome); }
            throw rejected;
        } catch (Exception failure) {
            synchronized (this) {
                summary.put("outcome", "fatal").put("exception", failure.toString())
                    .put("exception_class", failure.getClass().getName());
            }
            throw failure;
        } finally {
            synchronized (this) { summary.put("elapsed_ms", SystemClock.elapsedRealtime() - started); }
            if (heldWindow[0] != null) heldWindow[0].recycle();
            if (node != null) node.recycle();
        }
    }

    private static boolean hasLabel(CharSequence value) {
        if (value == null) return false;
        for (int index = 0; index < value.length(); index++) {
            char item = value.charAt(index);
            // Match the host's explicit XML whitespace predicate.
            if (item != ' ' && item != '\t' && item != '\r' && item != '\n') return true;
        }
        return false;
    }

    private void checkTime() {
        require(!completed.get() && SystemClock.elapsedRealtime() - started < 6000, "capture_deadline");
    }

    private void serialize(XmlSerializer xml, ByteArrayOutputStream bytes,
            AccessibilityNodeInfo node, int depth, int window, String expected, String nodePackage, int nodeWindow) throws Exception {
        checkTime(); require(depth <= 64 && ++nodes <= 4096 && bytes.size() <= LIMIT, "tree_limit");
        require(nodeWindow == window, "node_window_changed");
        require(expected.equals(nodePackage), "node_package_changed");
        CharSequence text = node.getText(); CharSequence description = node.getContentDescription();
        boolean visible = node.isVisibleToUser();
        if (visible && (hasLabel(text) || hasLabel(description))) visibleLabels++;
        Rect bounds = new Rect(); node.getBoundsInScreen(bounds);
        xml.startTag(null, "node");
        attribute(xml, "text", text); attribute(xml, "content-desc", description);
        attribute(xml, "resource-id", node.getViewIdResourceName()); attribute(xml, "package", nodePackage);
        attribute(xml, "class", node.getClassName());
        attribute(xml, "clickable", Boolean.toString(node.isClickable()));
        attribute(xml, "enabled", Boolean.toString(node.isEnabled()));
        attribute(xml, "visible-to-user", Boolean.toString(visible));
        attribute(xml, "bounds", "[" + bounds.left + "," + bounds.top + "][" + bounds.right + "," + bounds.bottom + "]");
        int children = node.getChildCount(); require(children <= 4096, "child_limit");
        for (int index = 0; index < children; index++) {
            AccessibilityNodeInfo child = node.getChild(index);
            if (child == null) throw new Polling.IncompleteChild();
            try {
                int childWindow = child.getWindowId(); CharSequence value = child.getPackageName();
                serialize(xml, bytes, child, depth + 1, window, expected, value == null ? null : value.toString(), childWindow);
            }
            finally { child.recycle(); }
        }
        xml.endTag(null, "node"); xml.flush(); require(bytes.size() <= LIMIT, "xml_size_limit");
    }

    private void attribute(XmlSerializer xml, String name, CharSequence value) throws Exception {
        String text = value == null ? "" : value.toString();
        require(text.length() <= 16384, "attribute_limit"); xml.attribute(null, name, text);
    }

    private static String hex(byte[] bytes) {
        StringBuilder value = new StringBuilder();
        for (byte item : bytes) value.append(String.format(java.util.Locale.ROOT, "%02x", item & 255));
        return value.toString();
    }

    private static void writeFresh(File file, byte[] data) throws Exception {
        requireFresh(file);
        try (FileOutputStream stream = new FileOutputStream(file)) {
            stream.write(data); stream.flush(); stream.getFD().sync();
        }
    }
    private static void requireFresh(File file) throws Exception {
        if (!file.createNewFile()) throw new IllegalStateException("output_already_present");
    }

    private void complete(boolean success, String error) {
        if (!completed.compareAndSet(false, true)) return;
        Bundle result = new Bundle();
        try {
            synchronized (this) {
                if (receipt == null || directory == null) throw new IllegalStateException("invalid_observer_request");
                if (candidate != null) {
                    writeFresh(new File(directory, "hierarchy.xml"), candidate.data);
                    java.util.Iterator<String> keys = candidate.metadata.keys();
                    while (keys.hasNext()) {
                        String key = keys.next(); receipt.put(key, candidate.metadata.get(key));
                    }
                }
                if (success && SystemClock.elapsedRealtime() - started >= 6000) {
                    success = false; error = "capture_deadline";
                }
                receipt.put("complete", true).put("result", success ? "PASS" : "FAIL")
                    .put("captured_at", Instant.now().toString())
                    .put("elapsed_ms", SystemClock.elapsedRealtime() - started);
                if (error != null) receipt.put("error", error);
                File partial = new File(directory, "receipt.partial");
                writeFresh(partial, (receipt.toString() + "\n").getBytes(StandardCharsets.UTF_8));
                require(partial.renameTo(new File(directory, "receipt.json")), "receipt_publish_failed");
                FileDescriptor descriptor = Os.open(directory.getPath(), OsConstants.O_RDONLY, 0);
                try { Os.fsync(descriptor); } finally { Os.close(descriptor); }
            }
            result.putString("stream", success ? "observation_complete\n" : "observation_failed\n");
        } catch (Exception failure) { result.putString("stream", "observation_failed:" + failure + "\n"); success = false; }
        finish(success ? -1 : 0, result);
    }
}
