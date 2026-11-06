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
        Map<String, Object> request = new HashMap<>(Map.of("version", 5, "id", 1, "generation", 2, "frame", 3, "load", 4, "layout", 5, "x", .5, "y", .5));
        Map<String, Object> event = new HashMap<>(Map.of("id", 1L, "generation", 2L, "frame", 3L, "load", 4L, "layout", 5L, "region", "chest"));
        Map<String, Object> rendered = new HashMap<>(event);
        require(BodyPickGuard.request(request), "Valid pick request rejected");
        require(BodyPickGuard.matches(request, event, rendered), "Current int/long bridge result rejected");
        for (String key : BodyPickGuard.TOKEN) {
            rendered.put(key, 100L);
            require(!BodyPickGuard.matches(request, event, rendered), "Stale " + key + " accepted");
            rendered.put(key, event.get(key));
        }
        for (String region : List.of("forearms", "adductors", "abductors")) {
            event.put("region", region);
            require(BodyPickGuard.matches(request, event, rendered), "Projected region rejected: " + region);
        }
        require(BodyPickGuard.REGIONS.size() == 13, "Region allowlist is not the thirteen display regions");
        event.put("region", "alien");
        require(!BodyPickGuard.matches(request, event, rendered), "Unknown region accepted");
        event.put("region", null);
        require(BodyPickGuard.matches(request, event, rendered), "Background result rejected");
        require(BodyPickGuard.VERSION == 5, "Bridge protocol is not version 5");
        for (int old : new int[] {2, 3, 4, 6}) {
            request.put("version", old); require(!BodyPickGuard.request(request), "Protocol " + old + " accepted");
        }
        request.put("version", 5);
        request.put("x", Double.NaN); require(!BodyPickGuard.request(request), "NaN accepted");
        request.put("x", 1); require(!BodyPickGuard.request(request), "Out-of-bounds coordinate accepted");
        request.put("x", .5); request.put("id", .5); require(!BodyPickGuard.request(request), "Fractional identity accepted");
        Map<String, Object> view = new HashMap<>(Map.of("zoom", 2.0, "x", .25, "y", -.5, "pitch", 0.0));
        require(BodyPickGuard.view(view), "Valid view rejected");
        for (double pitch : new double[] {Math.PI / 4, -Math.PI / 4, .3}) {
            view.put("pitch", pitch); require(BodyPickGuard.view(view), "Bounded pitch rejected: " + pitch);
        }
        for (double pitch : new double[] {Math.nextUp(Math.PI / 4), -Math.nextUp(Math.PI / 4), Math.PI / 2, Double.NaN, Double.POSITIVE_INFINITY}) {
            view.put("pitch", pitch); require(!BodyPickGuard.view(view), "Out-of-range pitch accepted: " + pitch);
        }
        view.put("pitch", 0.0);
        view.remove("pitch"); require(!BodyPickGuard.view(view), "Version-4 view without pitch accepted");
        view.put("pitch", "0"); require(!BodyPickGuard.view(view), "Non-numeric pitch accepted");
        view.put("pitch", 0.0); view.put("extra", 1.0); require(!BodyPickGuard.view(view), "Extra view key accepted");
        view.remove("extra"); view.put("zoom", 3.5); require(!BodyPickGuard.view(view), "Zoom past 3 accepted");
        view.put("zoom", 1.0); require(!BodyPickGuard.view(view), "Pan at unzoomed view accepted");
        view.put("x", 0.0); view.put("y", 0.0); require(BodyPickGuard.view(view), "Unzoomed level view rejected");
        System.out.println("PASS: protocol 5 view pitch bounds, version 4 and missing/out-of-range pitch rejected");
        System.out.println("PASS: native one-in-flight/latest-slot, hidden replacement, stale callback and disposal fences");
    }

    private static void require(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }
}
