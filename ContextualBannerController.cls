/**
 * ContextualBannerController
 *
 * The only class the LWC talks to. Thin by design - all logic lives in
 * ContextualBannerHelper.
 *
 * WHY THIS EXISTS
 *   The LWC no longer imports static resources directly. Previously every
 *   config file needed its own import statement in the JavaScript, which does
 *   not scale past a handful of files. Now Apex reads them all with one query
 *   and the LWC has a single import that never changes.
 *
 * SOQL COST - FIXED AT 2 PER PAGE LOAD
 *   1 query  -> all CTX_POLICY_* config files  (one query however many files)
 *   1 query  -> the record being viewed
 *   Independent of how many rules are configured.
 *
 * SAFETY
 *   Every entry point is wrapped so that a failure returns an empty list
 *   rather than an exception. The banner can degrade but can never blank the
 *   page with an error.
 */
public with sharing class ContextualBannerController {

    /**
     * Messages for a PolicyMaster__c record page.
     *
     * cacheable=true means the platform caches the result client side, so
     * revisiting the same record does not call Apex again.
     */
    @AuraEnabled(cacheable=true)
    public static List<ContextualBannerHelper.BannerMessage> getPolicyMessages(Id recordId) {

        List<ContextualBannerHelper.BannerMessage> empty =
            new List<ContextualBannerHelper.BannerMessage>();

        try {
            if (recordId == null) { return empty; }

            // 1 query - the record being viewed
            List<PolicyMaster__c> records = [
                SELECT Id, PolicyNumber__c
                FROM PolicyMaster__c
                WHERE Id = :recordId
                LIMIT 1
            ];

            if (records.isEmpty()) { return empty; }

            // 1 query - every config file, in one go
            List<ContextualBannerHelper.Rule> rules =
                ContextualBannerHelper.loadRules(ContextualBannerHelper.POLICY_PREFIX);

            return ContextualBannerHelper.match(rules, records[0].PolicyNumber__c);

        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR,
                'ContextualBanner - getPolicyMessages failed: ' + e.getMessage()
                + ' / ' + e.getStackTraceString());
            return empty;
        }
    }

    /**
     * Messages for a Contact record page.
     *
     * Built to the same shape so the Contact side can be switched on by
     * creating CTX_CONTACT_001 config files - no further code change.
     * The value matched against policyRecords is the contact's Id.
     */
    @AuraEnabled(cacheable=true)
    public static List<ContextualBannerHelper.BannerMessage> getContactMessages(Id recordId) {

        List<ContextualBannerHelper.BannerMessage> empty =
            new List<ContextualBannerHelper.BannerMessage>();

        try {
            if (recordId == null) { return empty; }

            List<ContextualBannerHelper.Rule> rules =
                ContextualBannerHelper.loadRules(ContextualBannerHelper.CONTACT_PREFIX);

            // no extra query needed - the Id is the record Id
            return ContextualBannerHelper.match(rules, String.valueOf(recordId));

        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR,
                'ContextualBanner - getContactMessages failed: ' + e.getMessage()
                + ' / ' + e.getStackTraceString());
            return empty;
        }
    }
}
