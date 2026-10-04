import { LightningElement, api, wire } from 'lwc';
import { getRecord } from 'lightning/uiRecordApi';
import getRules from '@salesforce/apex/ContextualBannerController.getRules';

/**
 * contextualBannerAlert
 *
 * Apex returns every rule for the object this page is on - one rule per
 * static resource file, each with its message and its list of records.
 * The comparison with the record being viewed happens here.
 *
 * Which value identifies the record, per object:
 *   PolicyMaster__c -> the PolicyNumber__c field
 *   Contact         -> the record Id
 */
const MATCH_FIELD = {
    PolicyMaster__c: 'PolicyNumber__c',
    Contact: 'Id'
};

const BANNER_CLASS =
    'slds-notify slds-notify_alert slds-theme_alert-texture slds-theme_warning';

export default class ContextualBannerAlert extends LightningElement {
    @api recordId;
    @api objectApiName;

    ruleObject;      // object to load rules for - stays undefined if unsupported
    recordFields;    // fields to read from the record - undefined when not needed
    matchField;
    rules;           // every rule for this object, from Apex
    fieldValue;      // this record's value read through Lightning Data Service

    connectedCallback() {
        const field = MATCH_FIELD[this.objectApiName];
        if (!field) { return; }               // unsupported object - show nothing

        this.matchField = field;
        this.ruleObject = this.objectApiName;
        // a Contact is identified by its Id, which is already known
        this.recordFields = field === 'Id' ? undefined : [this.objectApiName + '.' + field];
    }

    // One call returns the rules of every file for this object. The call takes
    // no record Id, so the browser can reuse the result for every record.
    @wire(getRules, { objectApiName: '$ruleObject' })
    wiredRules({ data, error }) {
        if (data) {
            this.rules = data;
        } else if (error) {
            this.logError(error, 'loading the rules');
        }
    }

    // Lightning Data Service - the record is already loaded for the page
    @wire(getRecord, { recordId: '$recordId', fields: '$recordFields' })
    wiredRecord({ data, error }) {
        if (data) {
            const f = data.fields[this.matchField];
            this.fieldValue = f ? f.value : undefined;
        } else if (error) {
            this.logError(error, 'reading the record');
        }
    }

    get currentValue() {
        return this.matchField === 'Id' ? this.recordId : this.fieldValue;
    }

    /** The banners to show: every rule whose list contains this record. */
    get banners() {
        const value = this.currentValue;
        if (!this.rules || value === undefined || value === null || value === '') {
            return [];
        }

        const target = String(value).trim().toUpperCase();

        return this.rules
            .filter(rule => Array.isArray(rule.policyRecords)
                && rule.policyRecords.some(v => String(v).trim().toUpperCase() === target))
            .map(rule => ({
                key: rule.name,
                message: rule.message,
                cssClass: BANNER_CLASS
            }));
    }

    logError(error, doing) {
        // a failure must never break the page - log the real message, show nothing
        console.error('Contextual banner - problem ' + doing + ':',
            (error && error.body && error.body.message) ? error.body.message : error);
    }
}
