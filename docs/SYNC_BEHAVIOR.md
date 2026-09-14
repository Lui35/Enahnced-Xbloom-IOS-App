# Automatic library sync

Before sign-in, bundled recipes remain available as an offline starting library. Signing in downloads all cloud recipe pages before replacing the existing local recipe library. A legitimately empty cloud library replaces the local recipes with an empty library. Invalid responses, interrupted downloads, or local save failures leave the previous library recoverable.

The cloud baseline is persisted per active account in `CloudSyncMetadata.recipeLibraryAccountID`. Existing installs establish it on the first successful sync after this update. Explicit sign-in requests a fresh recipe restore; ordinary launches/foreground syncs keep the established baseline and merge local edits, including offline changes. The starter seeder respects an established empty cloud library.

Recipes created while the initial cloud download is running are retained and uploaded. Restore records cloud IDs as the deletion baseline, so replacing starter recipes never produces cloud deletion requests for them. Recipe removal does not delete brew history snapshots. This change concerns recipe replacement; beans, brew history, and maintenance retain their existing merge behavior.

The app syncs on authenticated launch and foreground, and debounces local saves by one second. Failed attempts retry after 30 seconds while the app can execute and the account remains available. The cached account is retained if session refresh fails temporarily; requests still require a successfully refreshed session. iOS may suspend this work while closed, so reconnecting/reopening resumes synchronization.

Home presents sync status without a manual button. Settings groups Account & sync, Coffee library, Machine, and Storage & privacy. Manual Sync now is available in Account & sync for troubleshooting. Sign-in explains that cloud recipes replace the local recipe list.

Regression tests cover cloud data winning over starter/local recipes, empty cloud libraries, new recipes during restore, local-save failure and retry, and retained brew history. No cloud recipes are deleted as part of developing or testing this change.
