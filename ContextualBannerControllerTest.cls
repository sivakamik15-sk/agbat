/**
 * ContextualBannerControllerTest
 *
 * Deliberately does not create PolicyMaster__c records - required fields and
 * validation rules differ per org, which would make the test brittle. These
 * tests cover the entry points, the parsing, the matching and the failure
 * handling, which is where the logic lives.
 */
@isTest
private class ContextualBannerControllerTest {

    // ----------------------------------------------------------- entry points

    @isTest
    static void policyMessagesReturnsEmptyForNullId() {
        Test.startTest();
        List<ContextualBannerHelper.BannerMessage> result =
            ContextualBannerController.getPolicyMessages(null);
        Test.stopTest();

        System.assertNotEquals(null, result, 'should never return null');
        System.assertEquals(0, result.size(), 'no messages expected for a null Id');
    }

    @isTest
    static void contactMessagesReturnsEmptyForNullId() {
        Test.startTest();
        List<ContextualBannerHelper.BannerMessage> result =
            ContextualBannerController.getContactMessages(null);
        Test.stopTest();

        System.assertNotEquals(null, result, 'should never return null');
        System.assertEquals(0, result.size(), 'no messages expected for a null Id');
    }

    @isTest
    static void loadRulesHandlesBlankPrefix() {
        Test.startTest();
        List<ContextualBannerHelper.Rule> rules =
            ContextualBannerHelper.loadRules(null);
        Test.stopTest();

        System.assertEquals(0, rules.size(), 'a blank prefix should load nothing');
    }

    // -------------------------------------------------------------- matching

    @isTest
    static void matchFindsTheRightRule() {
        List<ContextualBannerHelper.Rule> rules = buildRules();

        Test.startTest();
        List<ContextualBannerHelper.BannerMessage> result =
            ContextualBannerHelper.match(rules, 'LS002876200');
        Test.stopTest();

        System.assertEquals(1, result.size(), 'exactly one rule should match');
        System.assertEquals('Message B', result[0].message, 'wrong rule matched');
    }

    @isTest
    static void matchIsCaseAndWhitespaceInsensitive() {
        List<ContextualBannerHelper.Rule> rules = buildRules();

        Test.startTest();
        List<ContextualBannerHelper.BannerMessage> result =
            ContextualBannerHelper.match(rules, '  ll013645400  ');
        Test.stopTest();

        System.assertEquals(1, result.size(),
            'should match despite different case and padding');
        System.assertEquals('Message A', result[0].message, 'wrong rule matched');
    }

    @isTest
    static void matchReturnsEveryApplicableRule() {
        List<ContextualBannerHelper.Rule> rules = buildRules();

        Test.startTest();
        // LL013645400 appears in rule A and in the shared rule C
        List<ContextualBannerHelper.BannerMessage> result =
            ContextualBannerHelper.match(rules, 'LL013645400');
        Test.stopTest();

        System.assertEquals(2, result.size(),
            'a record in two rules should produce two banners');
    }

    @isTest
    static void matchReturnsNothingForUnknownValue() {
        List<ContextualBannerHelper.Rule> rules = buildRules();

        Test.startTest();
        List<ContextualBannerHelper.BannerMessage> result =
            ContextualBannerHelper.match(rules, 'NOT_IN_ANY_RULE');
        Test.stopTest();

        System.assertEquals(0, result.size(), 'no rule should match');
    }

    @isTest
    static void matchHandlesBlankAndNullInput() {
        List<ContextualBannerHelper.Rule> rules = buildRules();

        Test.startTest();
        System.assertEquals(0, ContextualBannerHelper.match(rules, null).size(),
            'null value should match nothing');
        System.assertEquals(0, ContextualBannerHelper.match(rules, '').size(),
            'blank value should match nothing');
        System.assertEquals(0, ContextualBannerHelper.match(null, 'LS001').size(),
            'null rule list should match nothing');
        Test.stopTest();
    }

    @isTest
    static void matchSkipsRulesWithNoRecords() {
        List<ContextualBannerHelper.Rule> rules = new List<ContextualBannerHelper.Rule>();

        ContextualBannerHelper.Rule noRecords = new ContextualBannerHelper.Rule();
        noRecords.message = 'should never show';
        noRecords.policyRecords = null;
        rules.add(noRecords);

        Test.startTest();
        List<ContextualBannerHelper.BannerMessage> result =
            ContextualBannerHelper.match(rules, 'ANYTHING');
        Test.stopTest();

        System.assertEquals(0, result.size(), 'a rule with no records must be skipped');
    }

    // --------------------------------------------------------------- parsing

    @isTest
    static void jsonDeserialisesIntoRules() {
        String raw =
            '[{"policyRecords":["LS001","LS002"],' +
            ' "message":"Parsed message",' +
            ' "description":"Parsed description"}]';

        Test.startTest();
        List<ContextualBannerHelper.Rule> rules =
            (List<ContextualBannerHelper.Rule>)
                JSON.deserialize(raw, List<ContextualBannerHelper.Rule>.class);
        Test.stopTest();

        System.assertEquals(1, rules.size(), 'one rule expected');
        System.assertEquals(2, rules[0].policyRecords.size(), 'two records expected');
        System.assertEquals('Parsed message', rules[0].message, 'message not parsed');
        System.assertEquals('Parsed description', rules[0].description,
            'description not parsed');
    }

    // ------------------------------------------ the SOQL paths get exercised

    @isTest
    static void loadRulesCostsExactlyOneQuery() {
        // Reads every CTX_POLICY_* config file. The point of this test is the
        // query COUNT - one query however many files exist in the org.
        Test.startTest();
        List<ContextualBannerHelper.Rule> rules =
            ContextualBannerHelper.loadRules(ContextualBannerHelper.POLICY_PREFIX);
        Integer used = Limits.getQueries();
        Test.stopTest();

        System.assertNotEquals(null, rules, 'should never return null');
        System.assertEquals(1, used,
            'reading every config file must cost exactly one query, used: ' + used);
    }

    @isTest
    static void policyPathNeverCostsMoreThanTwoQueries() {
        // A well formed but non existent Id, built from the object's key
        // prefix. This exercises the record query without needing to create a
        // PolicyMaster__c record, whose required fields differ per org.
        String prefix = PolicyMaster__c.SObjectType.getDescribe().getKeyPrefix();
        Id noSuchRecord = Id.valueOf(prefix + '000000000000');

        Test.startTest();
        List<ContextualBannerHelper.BannerMessage> result =
            ContextualBannerController.getPolicyMessages(noSuchRecord);
        Integer used = Limits.getQueries();
        Test.stopTest();

        System.assertEquals(0, result.size(),
            'a non existent record should produce no messages');
        System.assert(used <= 2,
            'the policy path must never exceed two queries, used: ' + used);
    }

    @isTest
    static void contactPathNeverCostsMoreThanOneQuery() {
        Id noSuchContact = Id.valueOf('003000000000000');

        Test.startTest();
        List<ContextualBannerHelper.BannerMessage> result =
            ContextualBannerController.getContactMessages(noSuchContact);
        Integer used = Limits.getQueries();
        Test.stopTest();

        System.assertNotEquals(null, result, 'should never return null');
        System.assert(used <= 1,
            'the contact path reads config only - one query, used: ' + used);
    }

    // ----------------------------------------------------------------- helper

    private static List<ContextualBannerHelper.Rule> buildRules() {

        List<ContextualBannerHelper.Rule> rules = new List<ContextualBannerHelper.Rule>();

        ContextualBannerHelper.Rule a = new ContextualBannerHelper.Rule();
        a.policyRecords = new List<String>{ 'LL013645400' };
        a.message = 'Message A';
        a.description = 'Rule A';
        rules.add(a);

        ContextualBannerHelper.Rule b = new ContextualBannerHelper.Rule();
        b.policyRecords = new List<String>{ 'LS002876200' };
        b.message = 'Message B';
        b.description = 'Rule B';
        rules.add(b);

        ContextualBannerHelper.Rule c = new ContextualBannerHelper.Rule();
        c.policyRecords = new List<String>{ 'LL013645400', 'test12345' };
        c.message = 'Message C';
        c.description = 'Rule C - shared across records';
        rules.add(c);

        return rules;
    }
}
