Generate a base64 auth token: https://developer.atlassian.com/cloud/jira/platform/basic-auth-for-rest-apis/#supply-basic-auth-headers. Note that you need heightened Jira access to generate an API key and access some REST endpoints. The default user access does not suffice.

Put that token in `.jira-base64-auth`

Run `bundle install` once

Run this script with `ruby jira-time-in-status.rb`
