/**
 * ContextualBannerHelper
 *
 * All the logic for the contextual banner. Reads the configuration from
 * static resources and decides which messages apply to a record.
 *
 * KEY POINT - SOQL COST
 *   Reading the config costs ONE query no matter how many config files exist,
 *   because every file is fetched in a single query using a name prefix.
 *
 *       1 query   -> all CTX_POLICY_* config files
 *       1 query   -> the policy record being viewed
 *       --------
 *       2 queries total, fixed, regardless of how many rules are configured.
 *
 * NAMING CONVENTION
 *   Static resources must be named with the prefix below, then a number:
 *       CTX_POLICY_001, CTX_POLICY_002, CTX_POLICY_003 ...
 *   Add a new file following that pattern and it is picked up automatically.
 *   No code change is ever needed to add a file or a rule.
 */
public with sharing class ContextualBannerHelper {

    // ---------------------------------------------------------------- config

    /** Static resources whose name starts with this are policy config files. */
    public static final String POLICY_PREFIX = 'CTX_POLICY_';

    /** Static resources whose name starts with this are contact config files. */
    public static final String CONTACT_PREFIX = 'CTX_CONTACT_';

    // ------------------------------------------------------------ data shapes

    /**
     * One rule, as it appears in a config file.
     * Exactly three properties, by design.
     */
    public class Rule {
        public List<String> policyRecords;   // the records this rule applies to
        public String message;               // what is shown in the banner
        public String description;           // why the rule exists (not displayed)
    }

    /** What the LWC receives back. */
    public class BannerMessage {
        @AuraEnabled public String message     { get; set; }
        @AuraEnabled public String description { get; set; }

        public BannerMessage(String message, String description) {
            this.message = message;
            this.description = description;
        }
    }

    // --------------------------------------------------------- read the config

    /**
     * Loads every rule from every config file matching the prefix.
     * ONE SOQL query, however many files there are.
     *
     * A malformed file is skipped and logged - it can never blank the banner.
     */
    public static List<Rule> loadRules(String prefix) {

        List<Rule> allRules = new List<Rule>();

        if (String.isBlank(prefix)) { return allRules; }

        String pattern = prefix + '%';

        // ONE query for all config files
        List<StaticResource> files = [
            SELECT Name, Body
            FROM StaticResource
            WHERE Name LIKE :pattern
            ORDER BY Name
        ];

        for (StaticResource file : files) {
            try {
                if (file.Body == null) { continue; }

                String raw = file.Body.toString();
                if (String.isBlank(raw)) { continue; }

                List<Rule> fileRules = (List<Rule>) JSON.deserialize(raw, List<Rule>.class);

                if (fileRules != null) {
                    allRules.addAll(fileRules);
                }
            } catch (Exception e) {
                // one bad file must not stop the others
                System.debug(LoggingLevel.ERROR,
                    'ContextualBanner - could not parse ' + file.Name + ': ' + e.getMessage());
            }
        }

        System.debug('ContextualBanner - loaded ' + allRules.size()
            + ' rules from ' + files.size() + ' file(s) matching ' + pattern);

        return allRules;
    }

    // ------------------------------------------------------------- evaluation

    /**
     * Returns every message whose rule lists the given record value.
     * Comparison is case-insensitive and trims whitespace, matching how
     * SOQL behaved in the previous solution.
     */
    public static List<BannerMessage> match(List<Rule> rules, String recordValue) {

        List<BannerMessage> matched = new List<BannerMessage>();

        if (rules == null || rules.isEmpty() || String.isBlank(recordValue)) {
            return matched;
        }

        String target = recordValue.trim().toUpperCase();

        for (Rule r : rules) {
            if (r == null || r.policyRecords == null || r.policyRecords.isEmpty()) {
                continue;
            }

            for (String value : r.policyRecords) {
                if (value != null && value.trim().toUpperCase() == target) {
                    matched.add(new BannerMessage(r.message, r.description));
                    break;              // this rule matched - move to the next rule
                }
            }
        }

        System.debug('ContextualBanner - matched ' + matched.size()
            + ' rule(s) for value "' + recordValue + '"');

        return matched;
    }
}
