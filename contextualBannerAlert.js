import { LightningElement, api, wire } from 'lwc';

import getPolicyMessages from '@salesforce/apex/ContextualBannerController.getPolicyMessages';
import getContactMessages from '@salesforce/apex/ContextualBannerController.getContactMessages';

/**
 * contextualBannerAlert
 *
 * Displays configured banner messages on a record page.
 *
 * The configuration lives in static resources named CTX_POLICY_001,
 * CTX_POLICY_002 and so on. Apex reads them all in a single query and
 * returns only the messages that apply to this record.
 *
 * NOTE ON IMPORTS
 *   There are exactly two imports above, and they never change. Adding a
 *   hundred more config files requires no change to this file, because the
 *   files are found by name prefix in Apex rather than imported here.
 */
export default class ContextualBannerAlert extends LightningElement {
    @api recordId;
    @api objectApiName;

    messages = [];
    loaded = false;

    // -------------------------------------------------- PolicyMaster__c pages

    @wire(getPolicyMessages, { recordId: '$policyRecordId' })
    wiredPolicy({ data, error }) {
        if (data) {
            this.apply(data, 'policy');
        } else if (error) {
            this.report(error, 'policy');
        }
    }

    // ------------------------------------------------------- Contact pages

    @wire(getContactMessages, { recordId: '$contactRecordId' })
    wiredContact({ data, error }) {
        if (data) {
            this.apply(data, 'contact');
        } else if (error) {
            this.report(error, 'contact');
        }
    }

    /**
     * Only one of the two wires is given a record Id, so only one calls Apex.
     * The other stays undefined and never fires.
     */
    get policyRecordId() {
        return this.objectApiName === 'PolicyMaster__c' ? this.recordId : undefined;
    }

    get contactRecordId() {
        return this.objectApiName === 'Contact' ? this.recordId : undefined;
    }

    // ------------------------------------------------------------- rendering

    apply(data, source) {
        this.messages = (data || []).map((m, i) => ({
            key: source + '-' + i,
            message: m.message,
            description: m.description,
            cssClass: 'slds-notify slds-notify_alert slds-theme_alert-texture slds-theme_warning'
        }));
        this.loaded = true;

        console.log('Contextual banner - ' + source + ': '
            + this.messages.length + ' message(s) returned');
    }

    report(error, source) {
        // a failure must never blank the page - just log and show nothing
        this.loaded = true;
        console.error('Contextual banner - ' + source + ' call failed:',
            (error && error.body && error.body.message) ? error.body.message : error);
    }

    get hasMessages() {
        return this.messages.length > 0;
    }
}
