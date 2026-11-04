# GEOInflow experimental Linux builds

Rebuilds the public MIT-licensed [GEOInflow](https://github.com/yaojingang/GEOInflow) source at commit `6ba7c79d8d263ff620911fdccd90dd90be85dfb7` with its official `Dockerfile.liekan`. These are experimental downstream builds, not official upstream releases.

Only public source, build configuration and synthetic runtime checks belong here. No private website source, business data, live credentials or server configuration are included.

The manually triggered workflow uses a standard public Ubuntu runner. It does not use paid larger runners, Actions cache or artifact storage. Compiled root filesystems, source revision, image manifest, synthetic probe results and checksums are distributed as prerelease assets. Runtime capacity still requires independent validation on the intended host.

No default-password service is published by this workflow. Probe credentials are ephemeral. Exported root filesystems come from clean never-started image containers. Preserve upstream and dependency license notices when redistributing.
