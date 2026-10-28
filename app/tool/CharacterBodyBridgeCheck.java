package dev.animusstudio.alkion;

import java.util.ArrayList;
import java.util.List;

/** Exercises the production queue with deliberately delayed WebView completions. */
public final class CharacterBodyBridgeCheck {
    public static void main(String[] args) {
        List<String> sent = new ArrayList<>();
        List<Runnable> completed = new ArrayList<>();
        LatestBodyEvaluation queue = new LatestBodyEvaluation((script, done) -> {
            sent.add(script);
            completed.add(done);
        });
        queue.offer("initial");
        for (int i = 1; i <= 120; i++) queue.offer("turn=" + i);
        require(sent.equals(List.of("initial")), "Must retain one evaluation in flight");
        completed.get(0).run();
        require(sent.equals(List.of("initial", "turn=120")), "Must send only newest pending turn");
        queue.offer("visible=true");
        queue.offer("visible=false,paused=true");
        completed.get(0).run(); // An old duplicate callback cannot drain a new generation.
        require(sent.size() == 2, "Old completion revived pending work");
        completed.get(1).run();
        require(sent.get(2).equals("visible=false,paused=true"), "Hidden snapshot lost to stale display");
        queue.offer("resume");
        queue.close();
        completed.get(2).run();
        queue.offer("after-dispose");
        require(sent.size() == 3, "Disposed/process-gone queue sent work");
        LatestBodyEvaluation replacement = new LatestBodyEvaluation((script, done) -> sent.add(script));
        replacement.offer("replacement-view");
        completed.get(2).run();
        require(sent.equals(List.of("initial", "turn=120", "visible=false,paused=true", "replacement-view")),
            "Old view callback affected replacement");
        replacement.close();
        System.out.println("PASS: native one-in-flight/latest-slot, hidden replacement, stale callback and disposal fences");
    }

    private static void require(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }
}
