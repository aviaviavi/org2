# Property view demo

This synthetic corpus contains an editable saved card view. Open this folder as
an isolated OpenOrg development corpus, then choose **Property Views** in the
sidebar. The saved **Roadmap by assignee** view demonstrates filters, numeric
sorting, groups and inherited properties. Change **Layout** to **Table** and
**Apply View** to inspect the same rows in a table.

Click a STATUS or ASSIGNEE cell, choose **Preview Change**, then **Apply to Source**.
An inherited ASSIGNEE becomes a local override in the selected heading. The source
link opens its exact file and line. **Save View** writes the definition in `views/`.

From the repository root:

```sh
node dist/cli.js property-view query --dir examples/property-views --view roadmap
```

Copy the corpus before trying edits if you want to retain the fixture unchanged.
