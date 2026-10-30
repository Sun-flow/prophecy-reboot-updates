# Prophecy friend updates

The join window in a friend's Prophecy-Online folder reads `latest.json` here before each Join.
When the version differs, its updater (`Update-Prophecy.ps1`) updates itself and installs
`payload.zip`; `update.zip` is the bootstrap for join windows from before the updater. Only the join window's scripts and data
are in it, never game files. Published by `friend/Publish-FriendUpdate.ps1`.
