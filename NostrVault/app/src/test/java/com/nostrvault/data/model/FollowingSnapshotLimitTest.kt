package com.nostrvault.data.model

import org.junit.Assert.assertEquals
import org.junit.Test

class FollowingSnapshotLimitTest {
    // iOS FollowingSnapshot.maxSnapshots; the screen's footer quotes this number.
    @Test fun keepsAsManySnapshotsAsTheIPhone() = assertEquals(50, FollowingSnapshotStore.MAX_SNAPSHOTS)
}
