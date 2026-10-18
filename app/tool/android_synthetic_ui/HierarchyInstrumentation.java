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
            AccessibilityNodeInfo node = null;
            for (int attempt = 0; attempt < 3 && node == null; attempt++) {
                checkTime(); node = automation.getRootInActiveWindow();
                if (node == null) SystemClock.sleep(100);
            }
            require(node != null && expected.contentEquals(node.getPackageName()), "root_package_unavailable");
            AccessibilityWindowInfo window = node.getWindow();
            require(window != null && window.getId() == node.getWindowId()
                && window.isActive() && window.isFocused() && window.getDisplayId() == 0,
                "active_window_unavailable");
            Display display = ((DisplayManager) getTargetContext().getSystemService(Context.DISPLAY_SERVICE)).getDisplay(0);
            require(display != null, "display_unavailable");
            Point size = new Point(); display.getRealSize(size);
            synchronized (this) {
                receipt.put("root_package", node.getPackageName().toString())
                    .put("window_id", window.getId()).put("window_type", window.getType())
                    .put("window_active", window.isActive()).put("window_focused", window.isFocused())
                    .put("display_id", 0).put("rotation", display.getRotation())
                    .put("width", size.x).put("height", size.y);
            }
            ByteArrayOutputStream bytes = new ByteArrayOutputStream();
            XmlSerializer xml = Xml.newSerializer(); xml.setOutput(bytes, "UTF-8");
            xml.startDocument("UTF-8", true); xml.startTag(null, "hierarchy");
            xml.attribute(null, "rotation", Integer.toString(display.getRotation()));
            serialize(xml, bytes, node, 0, node.getWindowId());
            xml.endTag(null, "hierarchy"); xml.endDocument(); xml.flush();
            require(bytes.size() > 0 && bytes.size() <= LIMIT, "xml_size_limit");
            byte[] data = bytes.toByteArray();
            checkTime(); writeFresh(new File(directory, "hierarchy.xml"), data);
            synchronized (this) {
                receipt.put("node_count", nodes).put("xml_length", data.length)
                    .put("xml_sha256", hex(MessageDigest.getInstance("SHA-256").digest(data)));
            }
            complete(true, null);
        } catch (Exception failure) { complete(false, failure.toString()); }
    }

    private void checkTime() {
        require(!completed.get() && SystemClock.elapsedRealtime() - started < 6000, "capture_deadline");
    }

    private void serialize(XmlSerializer xml, ByteArrayOutputStream bytes,
            AccessibilityNodeInfo node, int depth, int window) throws Exception {
        checkTime(); require(depth <= 64 && ++nodes <= 4096 && bytes.size() <= LIMIT, "tree_limit");
        require(node.getWindowId() == window, "node_window_changed");
        Rect bounds = new Rect(); node.getBoundsInScreen(bounds);
        xml.startTag(null, "node");
        attribute(xml, "text", node.getText()); attribute(xml, "content-desc", node.getContentDescription());
        attribute(xml, "resource-id", node.getViewIdResourceName()); attribute(xml, "package", node.getPackageName());
        attribute(xml, "class", node.getClassName());
        attribute(xml, "clickable", Boolean.toString(node.isClickable()));
        attribute(xml, "enabled", Boolean.toString(node.isEnabled()));
        attribute(xml, "visible-to-user", Boolean.toString(node.isVisibleToUser()));
        attribute(xml, "bounds", "[" + bounds.left + "," + bounds.top + "][" + bounds.right + "," + bounds.bottom + "]");
        int children = node.getChildCount(); require(children <= 4096, "child_limit");
        for (int index = 0; index < children; index++) {
            AccessibilityNodeInfo child = node.getChild(index);
            require(child != null, "incomplete_child"); serialize(xml, bytes, child, depth + 1, window);
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
