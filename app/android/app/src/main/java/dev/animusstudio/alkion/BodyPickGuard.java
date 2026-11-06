package dev.animusstudio.alkion;

import java.util.Map;
import java.util.Set;

/** Dependency-free protocol guard shared by the native host and bridge checks. */
final class BodyPickGuard {
    /** Bridge protocol 5: the display view carries the camera pitch. */
    static final int VERSION = 5;
    static final double MAX_PITCH = Math.PI / 4;
    static final Set<String> REGIONS = Set.of("chest", "back", "shoulders", "biceps", "triceps", "quads", "hamstrings", "calves", "glutes", "core", "forearms", "adductors", "abductors");
    static final Set<String> TOKEN = Set.of("generation", "frame", "load", "layout");
    private static final Set<String> KEYS = Set.of("version", "id", "generation", "frame", "load", "layout", "x", "y");
    private static final Set<String> VIEW = Set.of("zoom", "x", "y", "pitch");
    static boolean integer(Object value) {
        return value instanceof Number && !(value instanceof Float) && !(value instanceof Double) &&
            ((Number) value).longValue() >= 0 && ((Number) value).longValue() <= 9007199254740991L;
    }
    static boolean request(Map<?, ?> value) {
        if (!value.keySet().equals(KEYS) || !Integer.valueOf(VERSION).equals(value.get("version"))) return false;
        for (String key : TOKEN) if (!integer(value.get(key))) return false;
        if (!integer(value.get("id"))) return false;
        for (String key : Set.of("x", "y")) {
            Object raw = value.get(key);
            if (!(raw instanceof Number)) return false;
            double n = ((Number) raw).doubleValue();
            if (!Double.isFinite(n) || n < 0 || n >= 1) return false;
        }
        return true;
    }
    /** Display viewport: zoom 1–3, pan within the zoomed reach, pitch within ±45°. */
    static boolean view(Map<?, ?> value) {
        if (!value.keySet().equals(VIEW)) return false;
        for (String key : VIEW) {
            if (!(value.get(key) instanceof Number) || !Double.isFinite(((Number) value.get(key)).doubleValue())) return false;
        }
        double zoom = ((Number) value.get("zoom")).doubleValue();
        if (zoom < 1 || zoom > 3) return false;
        for (String key : Set.of("x", "y")) {
            if (Math.abs(((Number) value.get(key)).doubleValue()) > (zoom - 1) / 2) return false;
        }
        return Math.abs(((Number) value.get("pitch")).doubleValue()) <= MAX_PITCH;
    }
    static boolean matches(Map<?, ?> request, Map<?, ?> event, Map<?, ?> rendered) {
        if (!request(request) || !(event.get("id") instanceof Number) || ((Number) request.get("id")).longValue() != ((Number) event.get("id")).longValue() || rendered == null) return false;
        for (String key : TOKEN) {
            if (!(event.get(key) instanceof Number) || !(rendered.get(key) instanceof Number) ||
                ((Number) request.get(key)).longValue() != ((Number) event.get(key)).longValue() ||
                ((Number) request.get(key)).longValue() != ((Number) rendered.get(key)).longValue()) return false;
        }
        return event.get("region") == null || REGIONS.contains(event.get("region"));
    }
}
