package com.idme.tools.orgseeder;

import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.net.URI;
import java.net.URLEncoder;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.time.Instant;
import java.util.ArrayList;
import java.util.Base64;
import java.util.List;

/**
 * OrgSeeder — seeds passport/immigration issuer organizations via the Org API.
 *
 * Fetches an OAuth2 access token from Core API using client credentials,
 * then POSTs each issuer from issuers.csv to POST /v1/organizations.
 *
 * This is a machine-to-machine (M2M) integration — claimantType and claimant
 * are omitted, so the API resolves the claimant to the Org UUID from the token.
 *
 * Usage:
 *   java -jar org-seeder.jar \
 *     --base-url    https://organizations-api.idme.dev \
 *     --token-url   https://core-api.idme.dev/api/v1/oauth/tokens \
 *     --client-id   <client-id> \
 *     --client-secret <client-secret> \
 *     [--dry-run]
 *
 * Request shape:
 * {
 *   "legalName":              "Ministry of Foreign Affairs of Japan",
 *   "organizationSector":     "Public",
 *   "organizationStructure":  "Federal",
 *   "jurisdictionOfFormation": "JP"
 * }
 */
public class OrgSeeder {

    private static final String ISSUERS_CSV       = "/issuers.csv";
    private static final String ORGANIZATIONS_PATH = "/v1/organizations";
    private static final int    TIMEOUT_SECONDS    = 10;
    private static final int    DELAY_MS           = 200;

    // Cached token state
    private static String  cachedToken;
    private static Instant tokenExpiry = Instant.EPOCH;

    public static void main(String[] args) throws Exception {
        Config config = Config.parse(args);

        if (config.help) {
            printUsage();
            return;
        }

        config.validate();

        List<Issuer> issuers = loadIssuers();
        System.out.printf("Loaded %d issuers from CSV%n", issuers.size());

        if (config.dryRun) {
            System.out.println("\n--- DRY RUN — no requests will be sent ---\n");
            for (Issuer issuer : issuers) {
                System.out.println("POST " + config.baseUrl + ORGANIZATIONS_PATH);
                System.out.println(buildRequestBody(issuer));
                System.out.println();
            }
            return;
        }

        HttpClient client = HttpClient.newBuilder()
                .connectTimeout(Duration.ofSeconds(TIMEOUT_SECONDS))
                .build();

        // Fetch token once (re-fetched automatically if it expires mid-run)
        String accessToken = getAccessToken(client, config);

        int success = 0;
        int failed  = 0;
        int skipped = 0;

        System.out.printf("%-70s %-12s %s%n", "Organization", "Status", "Detail");
        System.out.println("-".repeat(120));

        for (Issuer issuer : issuers) {
            // Refresh token if it's about to expire
            accessToken = getAccessToken(client, config);

            String body     = buildRequestBody(issuer);
            String shortName = truncate(issuer.legalName, 68);

            HttpRequest request = HttpRequest.newBuilder()
                    .uri(URI.create(config.baseUrl + ORGANIZATIONS_PATH))
                    .header("Content-Type", "application/json")
                    .header("Accept",       "application/json")
                    .header("Authorization", "Bearer " + accessToken)
                    .timeout(Duration.ofSeconds(TIMEOUT_SECONDS))
                    .POST(HttpRequest.BodyPublishers.ofString(body))
                    .build();

            try {
                HttpResponse<String> response = client.send(request, HttpResponse.BodyHandlers.ofString());
                int status = response.statusCode();

                if (status == 201 || status == 200) {
                    String uuid = extractJsonField(response.body(), "uuid", "");
                    System.out.printf("%-70s %-12s uuid=%s%n", shortName, status + " CREATED", uuid);
                    success++;
                } else if (status == 409) {
                    // Per spec: existing org is returned — not an error
                    String uuid = extractJsonField(response.body(), "uuid", "");
                    System.out.printf("%-70s %-12s uuid=%s (already exists)%n", shortName, "409 EXISTS", uuid);
                    skipped++;
                } else if (status == 422) {
                    System.out.printf("%-70s %-12s %s%n", shortName, "422 INVALID", truncate(response.body(), 60));
                    failed++;
                } else {
                    System.out.printf("%-70s %-12s %s%n", shortName, status + " FAIL", truncate(response.body(), 60));
                    failed++;
                }
            } catch (IOException | InterruptedException e) {
                System.out.printf("%-70s %-12s %s%n", shortName, "ERROR", e.getMessage());
                failed++;
            }

            Thread.sleep(DELAY_MS);
        }

        System.out.println("-".repeat(120));
        System.out.printf("Done.  Created: %d  Already existed: %d  Failed: %d  Total: %d%n",
                success, skipped, failed, issuers.size());
    }

    // -------------------------------------------------------------------------
    // Token management
    // -------------------------------------------------------------------------

    static String getAccessToken(HttpClient client, Config config) throws Exception {
        // Return cached token if still valid (with 30s safety buffer)
        if (cachedToken != null && Instant.now().isBefore(tokenExpiry.minusSeconds(30))) {
            return cachedToken;
        }

        String credentials = config.clientId + ":" + config.clientSecret;
        String encodedAuth = Base64.getEncoder()
                .encodeToString(credentials.getBytes(StandardCharsets.UTF_8));

        // Credentials go in Basic Auth header only — not duplicated in the form body
        String formBody = "grant_type=client_credentials"
                + "&scope=" + URLEncoder.encode("organizations:write", StandardCharsets.UTF_8);

        HttpRequest tokenRequest = HttpRequest.newBuilder()
                .uri(URI.create(config.tokenUrl))
                .header("Content-Type", "application/x-www-form-urlencoded")
                .header("Authorization", "Basic " + encodedAuth)
                .timeout(Duration.ofSeconds(TIMEOUT_SECONDS))
                .POST(HttpRequest.BodyPublishers.ofString(formBody))
                .build();

        HttpResponse<String> tokenResponse = client.send(tokenRequest, HttpResponse.BodyHandlers.ofString());

        if (tokenResponse.statusCode() != 200) {
            throw new RuntimeException("Token request failed: HTTP " + tokenResponse.statusCode()
                    + " — " + tokenResponse.body());
        }

        cachedToken = extractJsonField(tokenResponse.body(), "access_token", null);
        if (cachedToken == null) {
            throw new RuntimeException("access_token not found in token response: " + tokenResponse.body());
        }

        String expiresInStr = extractJsonField(tokenResponse.body(), "expires_in", "3600");
        long expiresIn = Long.parseLong(expiresInStr);
        tokenExpiry = Instant.now().plusSeconds(expiresIn);

        System.out.printf("[token] fetched, expires in %ds%n", expiresIn);
        return cachedToken;
    }

    // -------------------------------------------------------------------------
    // Request body — matches actual Org API field names
    // -------------------------------------------------------------------------

    static String buildRequestBody(Issuer issuer) {
        return "{\n"
                + "  \"legalName\":              " + jsonString(issuer.legalName) + ",\n"
                + "  \"organizationSector\":     " + jsonString(issuer.sector) + ",\n"
                + "  \"organizationStructure\":  " + jsonString(issuer.structure) + ",\n"
                + "  \"jurisdictionOfFormation\":" + jsonString(issuer.jurisdiction) + "\n"
                + "}";
        // claimantType and claimant are intentionally omitted — M2M integration;
        // the API resolves the claimant to the Org UUID from the access token.
    }

    // -------------------------------------------------------------------------
    // CSV loading
    // -------------------------------------------------------------------------

    static List<Issuer> loadIssuers() throws IOException {
        InputStream is = OrgSeeder.class.getResourceAsStream(ISSUERS_CSV);
        if (is == null) {
            throw new IllegalStateException("issuers.csv not found in classpath — check src/main/resources/issuers.csv");
        }
        List<Issuer> issuers = new ArrayList<>();
        try (BufferedReader reader = new BufferedReader(new InputStreamReader(is, StandardCharsets.UTF_8))) {
            String line;
            boolean header = true;
            while ((line = reader.readLine()) != null) {
                if (header) { header = false; continue; }
                line = line.trim();
                if (line.isEmpty()) continue;
                String[] cols = parseCsvLine(line);
                if (cols.length < 4) continue;
                issuers.add(new Issuer(cols[0].trim(), cols[1].trim(), cols[2].trim(), cols[3].trim()));
            }
        }
        return issuers;
    }

    /** Minimal CSV parser — handles quoted fields containing commas. */
    static String[] parseCsvLine(String line) {
        List<String> fields = new ArrayList<>();
        StringBuilder sb = new StringBuilder();
        boolean inQuotes = false;
        for (int i = 0; i < line.length(); i++) {
            char c = line.charAt(i);
            if (c == '"') {
                inQuotes = !inQuotes;
            } else if (c == ',' && !inQuotes) {
                fields.add(sb.toString());
                sb.setLength(0);
            } else {
                sb.append(c);
            }
        }
        fields.add(sb.toString());
        return fields.toArray(new String[0]);
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    static String jsonString(String value) {
        return "\"" + value.replace("\\", "\\\\").replace("\"", "\\\"") + "\"";
    }

    static String truncate(String s, int max) {
        if (s == null) return "";
        return s.length() <= max ? s : s.substring(0, max - 1) + "…";
    }

    /**
     * Minimal JSON string/number field extractor.
     * Returns defaultValue if the field is not found.
     */
    static String extractJsonField(String json, String field, String defaultValue) {
        String key = "\"" + field + "\"";
        int idx = json.indexOf(key);
        if (idx < 0) return defaultValue;
        int colon = json.indexOf(":", idx + key.length());
        if (colon < 0) return defaultValue;
        int valueStart = colon + 1;
        // Skip whitespace
        while (valueStart < json.length() && Character.isWhitespace(json.charAt(valueStart))) valueStart++;
        if (valueStart >= json.length()) return defaultValue;
        if (json.charAt(valueStart) == '"') {
            // String value
            int start = valueStart + 1;
            int end   = json.indexOf("\"", start);
            return end < 0 ? defaultValue : json.substring(start, end);
        } else {
            // Numeric / boolean value — read until delimiter
            int end = valueStart;
            while (end < json.length() && ",}]\n".indexOf(json.charAt(end)) < 0) end++;
            return json.substring(valueStart, end).trim();
        }
    }

    static void printUsage() {
        System.out.println("Usage: java -jar org-seeder.jar [options]");
        System.out.println();
        System.out.println("Required:");
        System.out.println("  --base-url       <url>    Org API base URL  (e.g. https://organizations-api.idme.dev)");
        System.out.println("  --token-url      <url>    Core API token URL (e.g. https://core-api.idme.dev/api/v1/oauth/tokens)");
        System.out.println("  --client-id      <id>     OAuth2 client ID");
        System.out.println("  --client-secret  <secret> OAuth2 client secret");
        System.out.println();
        System.out.println("Optional:");
        System.out.println("  --dry-run                 Print request bodies without sending");
        System.out.println("  --help                    Show this help");
        System.out.println();
        System.out.println("Example (staging):");
        System.out.println("  java -jar org-seeder.jar \\");
        System.out.println("    --base-url     https://organizations-api.staging.idme.com \\");
        System.out.println("    --token-url    https://core-api.staging.idme.com/api/v1/oauth/tokens \\");
        System.out.println("    --client-id    abc123 \\");
        System.out.println("    --client-secret mysecret");
    }

    // -------------------------------------------------------------------------
    // Data classes
    // -------------------------------------------------------------------------

    record Issuer(String legalName, String sector, String structure, String jurisdiction) {}

    static class Config {
        String  baseUrl;
        String  tokenUrl;
        String  clientId;
        String  clientSecret;
        boolean dryRun = false;
        boolean help   = false;

        static Config parse(String[] args) {
            Config c = new Config();
            for (int i = 0; i < args.length; i++) {
                switch (args[i]) {
                    case "--base-url"      -> c.baseUrl       = args[++i];
                    case "--token-url"     -> c.tokenUrl      = args[++i];
                    case "--client-id"     -> c.clientId      = args[++i];
                    case "--client-secret" -> c.clientSecret  = args[++i];
                    case "--dry-run"       -> c.dryRun        = true;
                    case "--help"          -> c.help          = true;
                    default -> System.err.println("Unknown argument: " + args[i]);
                }
            }
            return c;
        }

        void validate() {
            List<String> missing = new ArrayList<>();
            if (baseUrl       == null) missing.add("--base-url");
            if (tokenUrl      == null) missing.add("--token-url");
            if (clientId      == null) missing.add("--client-id");
            if (clientSecret  == null) missing.add("--client-secret");
            if (!missing.isEmpty()) {
                throw new IllegalArgumentException("Missing required arguments: " + String.join(", ", missing));
            }
        }
    }
}
