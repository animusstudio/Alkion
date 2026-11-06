package dev.animusstudio.alkion;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.HashMap;

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
        Map<String, Object> request = new HashMap<>(Map.of("version", 3, "id", 1, "generation", 2, "frame", 3, "load", 4, "layout", 5, "x", .5, "y", .5));
        Map<String, Object> event = new HashMap<>(Map.of("id", 1L, "generation", 2L, "frame", 3L, "load", 4L, "layout", 5L, "region", "chest"));
        Map<String, Object> rendered = new HashMap<>(event);
        require(BodyPickGuard.request(request), "Valid pick request rejected");
        require(BodyPickGuard.matches(request, event, rendered), "Current int/long bridge result rejected");
        for (String key : BodyPickGuard.TOKEN) {
            rendered.put(key, 100L);
            require(!BodyPickGuard.matches(request, event, rendered), "Stale " + key + " accepted");
            rendered.put(key, event.get(key));
        }
        event.put("region", "forearms");
        require(BodyPickGuard.matches(request, event, rendered), "Projected region rejected");
        event.put("region", "alien");
        require(!BodyPickGuard.matches(request, event, rendered), "Unknown region accepted");
        event.put("region", null);
        require(BodyPickGuard.matches(request, event, rendered), "Background result rejected");
        request.put("version", 2); require(!BodyPickGuard.request(request), "Old protocol accepted");
        request.put("version", 3);
        request.put("x", Double.NaN); require(!BodyPickGuard.request(request), "NaN accepted");
        request.put("x", 1); require(!BodyPickGuard.request(request), "Out-of-bounds coordinate accepted");
        request.put("x", .5); request.put("id", .5); require(!BodyPickGuard.request(request), "Fractional identity accepted");
        System.out.println("PASS: native one-in-flight/latest-slot, hidden replacement, stale callback and disposal fences");
    }

    private static void require(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }
}
