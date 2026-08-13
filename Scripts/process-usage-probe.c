#include <errno.h>
#include <inttypes.h>
#include <libproc.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/resource.h>

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "Usage: %s PID\n", argv[0]);
        return 2;
    }

    char *end = NULL;
    long value = strtol(argv[1], &end, 10);
    if (value <= 0 || end == argv[1] || *end != '\0') {
        fprintf(stderr, "Invalid PID: %s\n", argv[1]);
        return 2;
    }

    struct rusage_info_v4 usage = {0};
    if (proc_pid_rusage((int)value, RUSAGE_INFO_V4, (rusage_info_t *)&usage) != 0) {
        perror("proc_pid_rusage");
        return 1;
    }

    printf("%" PRIu64 ",%" PRIu64 ",%" PRIu64 ",%" PRIu64 "\n",
           usage.ri_resident_size,
           usage.ri_phys_footprint,
           usage.ri_diskio_bytesread,
           usage.ri_diskio_byteswritten);
    return 0;
}
