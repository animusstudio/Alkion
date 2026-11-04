package dev.animusstudio.alkion;

import java.util.Map;
import java.util.Set;

/** Dependency-free protocol guard shared by the native host and bridge checks. */
final class BodyPickGuard {
    static final Set<String> REGIONS = Set.of("chest", "back", "shoulders", "biceps", "triceps", "quads", "hamstrings", "calves");
    static final Set<String> TOKEN = Set.of("generation", "frame", "load", "layout");
    private static final Set<String> KEYS = Set.of("version", "id", "generation", "frame", "load", "layout", "x", "y");
    static boolean integer(Object value) {
        return value instanceof Number && !(value instanceof Float) && !(value instanceof Double) &&
            ((Number) value).longValue() >= 0 && ((Number) value).longValue() <= 9007199254740991L;
    }
    static boolean request(Map<?, ?> value) {
        if (!value.keySet().equals(KEYS) || !Integer.valueOf(2).equals(value.get("version"))) return false;
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
