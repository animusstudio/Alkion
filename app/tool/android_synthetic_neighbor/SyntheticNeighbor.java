package io.github.psychonaut0.reps;

import android.app.Activity;
import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.content.ContentProvider;
import android.content.ContentValues;
import android.database.Cursor;
import android.database.MatrixCursor;
import android.net.Uri;
import android.os.Bundle;
import android.widget.TextView;
import java.io.File;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;
import org.json.JSONObject;

// Synthetic package-neighbor fixture. Contains no legacy implementation or sync.
public final class SyntheticNeighbor extends Activity {
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        TextView view = new TextView(this);
        view.setText("Synthetic Reps package neighbor — test data only");
        setContentView(view);
        String run = getIntent().getStringExtra("run_id");
        if (run == null || !run.matches("[a-f0-9]{32}")) {
            view.setText("Synthetic fixture requires an explicit proof run ID.");
            return;
        }
        try {
            File file = new File(getFilesDir(), "synthetic-neighbor.json");
            // First launch only; restarting never replaces another run's state.
            if (file.exists()) throw new IllegalStateException("Fixture already initialized");
            JSONObject value = new JSONObject();
            value.put("format", "alkion-synthetic-neighbor/1");
            value.put("run_id", run);
            value.put("sentinel", "synthetic-only-keep-exact");
            try (FileOutputStream output = new FileOutputStream(file)) {
                output.write(value.toString().getBytes(StandardCharsets.UTF_8));
                output.getFD().sync();
            }
            NotificationManager manager = getSystemService(NotificationManager.class);
            manager.createNotificationChannel(new NotificationChannel(
                "synthetic.legacy.workout", "Synthetic legacy neighbor", NotificationManager.IMPORTANCE_LOW));
            // Permission behavior is qualified later; no prompt or permission bypass.
            if (checkSelfPermission("android.permission.POST_NOTIFICATIONS") == 0) {
                manager.notify(4101, new Notification.Builder(this, "synthetic.legacy.workout")
                    .setSmallIcon(android.R.drawable.ic_dialog_info)
                    .setContentTitle("Synthetic neighbor")
                    .setContentText("Fixture state must remain separate")
                    .build());
            }
        } catch (Exception error) {
            view.setText("Synthetic fixture failed: " + error.getClass().getSimpleName());
        }
    }

    public static final class LegacyProvider extends ContentProvider {
        @Override public boolean onCreate() { return true; }
        @Override public String getType(Uri uri) { return "application/octet-stream"; }
        @Override public Cursor query(Uri uri, String[] projection, String selection,
                                      String[] selectionArgs, String sortOrder) {
            MatrixCursor cursor = new MatrixCursor(new String[]{"fixture"});
            cursor.addRow(new Object[]{"synthetic-only"});
            return cursor;
        }
        @Override public Uri insert(Uri uri, ContentValues values) {
            throw new UnsupportedOperationException("Read-only synthetic fixture");
        }
        @Override public int update(Uri uri, ContentValues values, String selection, String[] args) {
            throw new UnsupportedOperationException("Read-only synthetic fixture");
        }
        @Override public int delete(Uri uri, String selection, String[] args) {
            throw new UnsupportedOperationException("Read-only synthetic fixture");
        }
    }
}

