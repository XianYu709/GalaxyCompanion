package com.galaxycompanion.watch.health

/**
 * Applies the Watch's bounded local-retention policy without conflating a
 * later revision of an existing sample with a record that was actually
 * evicted. The watermark is an `afterCursor` that a phone must already have
 * durably persisted before the remaining records can be recovered safely.
 */
internal object WatchHealthRetentionWindow {
    data class Result(
        val retained: List<StoredWatchHealthSample>,
        val evictedThroughCursor: Long
    )

    fun retain(
        samples: List<StoredWatchHealthSample>,
        maximumRetainedSamples: Int,
        previousEvictedThroughCursor: Long
    ): Result {
        require(maximumRetainedSamples > 0)
        require(previousEvictedThroughCursor >= 0L)

        val ordered = samples.sortedBy(StoredWatchHealthSample::cursor)
        val evicted = if (ordered.size > maximumRetainedSamples) {
            ordered.dropLast(maximumRetainedSamples)
        } else {
            emptyList()
        }
        val evictedThroughCursor = maxOf(
            previousEvictedThroughCursor,
            evicted.maxOfOrNull(StoredWatchHealthSample::cursor) ?: 0L
        )
        return Result(
            retained = ordered.takeLast(maximumRetainedSamples),
            evictedThroughCursor = evictedThroughCursor
        )
    }

    fun requiresRecovery(afterCursor: Long, evictedThroughCursor: Long): Boolean {
        require(afterCursor >= 0L)
        require(evictedThroughCursor >= 0L)
        return afterCursor < evictedThroughCursor
    }
}
