#include <stdint.h>
#include <stdio.h>
#include <time.h>

int
main(void)
{
	struct timespec now;
	uint64_t nanoseconds;

	if (clock_gettime(CLOCK_MONOTONIC_RAW, &now) != 0) {
		perror("clock_gettime");
		return 1;
	}

	nanoseconds = (uint64_t)now.tv_sec * UINT64_C(1000000000)
	    + (uint64_t)now.tv_nsec;
	if (printf("%llu\n", (unsigned long long)nanoseconds) < 0) {
		return 1;
	}

	return 0;
}
