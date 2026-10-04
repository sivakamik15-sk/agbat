/**
 * ContextualBannerHelper
 *
 * Reads the banner rules from static resources.
 *
 * ONE RULE PER FILE
 *   Every static resource holds exactly one rule, so a mistake in one file
 *   can never affect another rule.
 *
 *   {
 *     "message": "text shown in the banner (HTML allowed)",
 *     "description": "why the rule exists - never displayed",
 *     "policyRecords": ["value1", "value2"]
 *   }
 *
 * NAMING CONVENTION  (the prefix decides which object a file belongs to)
 *   PolicyMaster__c  ->  CTX_POLICY_001, CTX_POLICY_002, ...
 *   Contact          ->  CTX_CONTACT_001, CTX_CONTACT_002, ...
 *   A Policy page loads only CTX_POLICY_* files, a Contact page only
 *   CTX_CONTACT_* files.
 *
 * SOQL COST
 *   ONE query for all the files of an object, however many files there are.
 *   The comparison with the record happens in the LWC, not here.
 */
public with sharing class ContextualBannerHelper {

    /** One rule = one file. What the LWC receives. */
    public class Rule {
        @AuraEnabled public String name;                 // static resource name - set here, not in the file
        @AuraEnabled public String message;
        @AuraEnabled public String description;
        @AuraEnabled public List<String> policyRecords;
    }

    /** The name prefix decides which object a config file belongs to. */
    public static final String POLICY_PREFIX  = 'CTX_POLICY_';
    public static final String CONTACT_PREFIX = 'CTX_CONTACT_';

    /** A file listing more records than this is rejected and logged. */
    @TestVisible
    private static Integer maxRecordsPerFile = 50000;

    /** Rules for PolicyMaster__c pages - reads ONLY the CTX_POLICY_* files. */
    public static List<Rule> getPolicyRules() {
        return loadRules(POLICY_PREFIX);
    }

    /** Rules for Contact pages - reads ONLY the CTX_CONTACT_* files. */
    public static List<Rule> getContactRules() {
        return loadRules(CONTACT_PREFIX);
    }

    /**
     * Loads every rule whose static resource name starts with the prefix.
     * ONE SOQL query. A bad file is skipped and logged, never fatal.
     */
    public static List<Rule> loadRules(String prefix) {

        List<Rule> rules = new List<Rule>();
        if (String.isBlank(prefix)) { return rules; }

        String pattern = prefix + '%';

        List<StaticResource> files = [
            SELECT Name, Body
            FROM StaticResource
            WHERE Name LIKE :pattern
            ORDER BY Name
        ];

        for (StaticResource file : files) {
            // in LIKE an underscore matches any single character, so confirm
            // the name really starts with the prefix
            if (!file.Name.startsWithIgnoreCase(prefix)) { continue; }

            String raw = (file.Body == null) ? null : file.Body.toString();
            Rule r = parseRule(file.Name, raw);
            if (r != null) { rules.add(r); }
        }

        System.debug('ContextualBanner - ' + rules.size() + ' valid rule(s) from '
            + files.size() + ' file(s) matching ' + pattern);

        return rules;
    }

    /**
     * Turns the text of one file into a Rule, or returns null (and logs why)
     * if the file cannot be used.
     */
    public static Rule parseRule(String fileName, String raw) {

        if (String.isBlank(raw)) {
            logSkip(fileName, 'the file is empty');
            return null;
        }

        // an editor may add a byte order mark, which breaks JSON.deserialize
        String bom = String.fromCharArray(new List<Integer>{ 65279 });
        String text = raw;
        if (text.startsWith(bom)) { text = text.substring(1); }

        Rule r;
        try {
            r = (Rule) JSON.deserialize(text, Rule.class);
        } catch (Exception e) {
            // also catches the old format, where a file held an array of rules
            logSkip(fileName, 'not valid JSON for a single rule - ' + e.getMessage());
            return null;
        }

        if (r == null || String.isBlank(r.message)) {
            logSkip(fileName, '"message" is missing or blank');
            return null;
        }
        if (r.policyRecords == null || r.policyRecords.isEmpty()) {
            logSkip(fileName, '"policyRecords" is missing or empty');
            return null;
        }
        if (r.policyRecords.size() > maxRecordsPerFile) {
            logSkip(fileName, 'it lists ' + r.policyRecords.size()
                + ' records, the limit is ' + maxRecordsPerFile);
            return null;
        }

        r.name = fileName;
        return r;
    }

    private static void logSkip(String fileName, String reason) {
        System.debug(LoggingLevel.ERROR,
            'ContextualBanner - skipped ' + fileName + ': ' + reason);
    }
}
