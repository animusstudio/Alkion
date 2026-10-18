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
    private int observedWindow = -1;
    private int observedWindowType = -1;

    /** The same finite controller is exercised on the host; it has no Android dependency. */
    static final class Polling {
        static final int MAX_SAMPLES = 40;
        static final long SAMPLE_BUDGET_MS = 5000;
        interface Clock { long now(); void pause(long milliseconds); }
        interface Probe { boolean sample(int index) throws Exception; }

        static int run(Clock clock, Probe probe, long started) throws Exception {
            long deadline = started + SAMPLE_BUDGET_MS;
            for (int index = 1; index <= MAX_SAMPLES; index++) {
                if (clock.now() >= deadline) throw new IllegalStateException("readiness_deadline");
                boolean ready = probe.sample(index);
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

    private boolean sample(UiAutomation automation, String expected, boolean needsLabels, int index)
            throws Exception {
        checkTime();
        JSONObject summary = new JSONObject().put("index", index).put("cache_cleared", false)
            .put("root_available", false).put("ready", false).put("node_count", 0)
            .put("visible_label_count", 0).put("window_id", -1).put("xml_length", 0)
            .put("xml_sha256", "");
        synchronized (this) {
            require(!completed.get(), "capture_deadline");
            samples.put(summary); receipt.put("sample_count", samples.length());
        }
        AccessibilityNodeInfo node = null;
        AccessibilityWindowInfo window = null;
        try {
            // API36 returns false when this connection has no cache; failures throw.
            boolean cleared = automation.clearCache();
            synchronized (this) { summary.put("cache_cleared", cleared); }
            node = automation.getRootInActiveWindow();
            checkTime();
            if (node == null) return false;
            require(expected.contentEquals(node.getPackageName()), "root_package_changed");
            window = node.getWindow();
            require(window != null && window.getId() == node.getWindowId()
                && window.isActive() && window.isFocused() && window.getDisplayId() == 0,
                "active_window_unavailable");
            require(observedWindow == -1 || (observedWindow == window.getId()
                && observedWindowType == window.getType()), "sample_window_changed");
            observedWindow = window.getId(); observedWindowType = window.getType();
            Display display = ((DisplayManager) getTargetContext().getSystemService(Context.DISPLAY_SERVICE)).getDisplay(0);
            require(display != null, "display_unavailable");
            Point size = new Point(); display.getRealSize(size);
            nodes = 0; visibleLabels = 0;
            ByteArrayOutputStream bytes = new ByteArrayOutputStream();
            XmlSerializer xml = Xml.newSerializer(); xml.setOutput(bytes, "UTF-8");
            xml.startDocument("UTF-8", true); xml.startTag(null, "hierarchy");
            xml.attribute(null, "rotation", Integer.toString(display.getRotation()));
            serialize(xml, bytes, node, 0, node.getWindowId(), expected);
            xml.endTag(null, "hierarchy"); xml.endDocument(); xml.flush();
            require(bytes.size() > 0 && bytes.size() <= LIMIT, "xml_size_limit");
            byte[] data = bytes.toByteArray();
            String hash = hex(MessageDigest.getInstance("SHA-256").digest(data));
            boolean ready = !needsLabels || visibleLabels > 0;
            JSONObject metadata = new JSONObject().put("root_package", node.getPackageName().toString())
                .put("window_id", window.getId()).put("window_type", window.getType())
                .put("window_active", window.isActive()).put("window_focused", window.isFocused())
                .put("display_id", 0).put("rotation", display.getRotation()).put("width", size.x).put("height", size.y)
                .put("node_count", nodes).put("visible_label_count", visibleLabels)
                .put("xml_length", data.length).put("xml_sha256", hash).put("candidate_sample", index);
            synchronized (this) {
                require(!completed.get(), "capture_deadline");
                candidate = new Candidate(data, metadata);
                summary.put("root_available", true).put("ready", ready).put("node_count", nodes)
                    .put("visible_label_count", visibleLabels).put("window_id", window.getId())
                    .put("xml_length", data.length).put("xml_sha256", hash);
            }
            return ready;
        } finally {
            synchronized (this) { summary.put("elapsed_ms", SystemClock.elapsedRealtime() - started); }
            if (window != null) window.recycle();
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
            AccessibilityNodeInfo node, int depth, int window, String expected) throws Exception {
        checkTime(); require(depth <= 64 && ++nodes <= 4096 && bytes.size() <= LIMIT, "tree_limit");
        require(node.getWindowId() == window, "node_window_changed");
        require(expected.contentEquals(node.getPackageName()), "node_package_changed");
        CharSequence text = node.getText(); CharSequence description = node.getContentDescription();
        if (node.isVisibleToUser() && (hasLabel(text) || hasLabel(description))) visibleLabels++;
        Rect bounds = new Rect(); node.getBoundsInScreen(bounds);
        xml.startTag(null, "node");
        attribute(xml, "text", text); attribute(xml, "content-desc", description);
        attribute(xml, "resource-id", node.getViewIdResourceName()); attribute(xml, "package", node.getPackageName());
        attribute(xml, "class", node.getClassName());
        attribute(xml, "clickable", Boolean.toString(node.isClickable()));
        attribute(xml, "enabled", Boolean.toString(node.isEnabled()));
        attribute(xml, "visible-to-user", Boolean.toString(node.isVisibleToUser()));
        attribute(xml, "bounds", "[" + bounds.left + "," + bounds.top + "][" + bounds.right + "," + bounds.bottom + "]");
        int children = node.getChildCount(); require(children <= 4096, "child_limit");
        for (int index = 0; index < children; index++) {
            AccessibilityNodeInfo child = node.getChild(index);
            require(child != null, "incomplete_child");
            try { serialize(xml, bytes, child, depth + 1, window, expected); }
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
