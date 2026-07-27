#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <unistd.h>

int
main(int argc, char **argv)
{
	char *procs_path;
	char pid_buffer[32];
	int procs_fd;
	int path_length;
	int pid_length;
	ssize_t written;

	if (argc < 3) {
		fprintf(stderr, "usage: cgroup-exec CGROUP COMMAND [ARG...]\n");
		return 2;
	}

	path_length = snprintf(NULL, 0, "%s/cgroup.procs", argv[1]);
	if (path_length < 0) {
		return 1;
	}
	procs_path = malloc((size_t)path_length + 1);
	if (procs_path == NULL) {
		perror("malloc");
		return 1;
	}
	if (snprintf(procs_path, (size_t)path_length + 1, "%s/cgroup.procs",
	    argv[1]) != path_length) {
		free(procs_path);
		return 1;
	}

	procs_fd = open(procs_path, O_WRONLY | O_CLOEXEC);
	if (procs_fd < 0) {
		fprintf(stderr, "cgroup-exec: open %s: %s\n", procs_path,
		    strerror(errno));
		free(procs_path);
		return 1;
	}
	free(procs_path);

	pid_length = snprintf(pid_buffer, sizeof(pid_buffer), "%ld\n",
	    (long)getpid());
	if (pid_length < 0 || (size_t)pid_length >= sizeof(pid_buffer)) {
		close(procs_fd);
		return 1;
	}
	written = write(procs_fd, pid_buffer, (size_t)pid_length);
	if (written != pid_length) {
		fprintf(stderr, "cgroup-exec: write cgroup.procs: %s\n",
		    written < 0 ? strerror(errno) : "short write");
		close(procs_fd);
		return 1;
	}
	if (close(procs_fd) != 0) {
		perror("cgroup-exec: close");
		return 1;
	}

	execvp(argv[2], &argv[2]);
	fprintf(stderr, "cgroup-exec: exec %s: %s\n", argv[2],
	    strerror(errno));
	return 127;
}
