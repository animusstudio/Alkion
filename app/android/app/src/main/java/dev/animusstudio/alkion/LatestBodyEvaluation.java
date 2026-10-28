package dev.animusstudio.alkion;

import java.util.function.BiConsumer;

/** UI-thread owned: one WebView evaluation and one replaceable latest snapshot. */
final class LatestBodyEvaluation {
    private final BiConsumer<String, Runnable> evaluate;
    private String pending;
    private boolean busy;
    private boolean closed;
    private long generation;

    LatestBodyEvaluation(BiConsumer<String, Runnable> evaluate) {
        this.evaluate = evaluate;
    }

    void offer(String script) {
        if (closed) return;
        pending = script;
        drain();
    }

    private void drain() {
        if (closed || busy || pending == null) return;
        String script = pending;
        pending = null;
        busy = true;
        long ticket = ++generation;
        evaluate.accept(script, () -> {
            if (closed || ticket != generation || !busy) return;
            busy = false;
            drain();
        });
    }

    void close() {
        closed = true;
        pending = null;
        generation++;
    }
}
