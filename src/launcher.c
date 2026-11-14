#include <mach-o/dyld.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv)
{
    (void)argc;
    const char suffix[] = "/OCRClientProcess.app/Contents/MacOS/OCRClientProcess";
    const char worker_suffix[] = "/OCRClientProcessReal.app/Contents/MacOS/OCRClientProcess";
    const char library_suffix[] = "/ScanSnapParentCompat.dylib";
    char probe[1];
    uint32_t size = sizeof(probe);
    (void)_NSGetExecutablePath(probe, &size);
    char *raw = malloc(size);
    if (!raw) {
        perror("OCR launcher: malloc");
        return 1;
    }
    if (_NSGetExecutablePath(raw, &size) != 0) {
        fprintf(stderr, "OCR launcher: cannot determine executable path\n");
        free(raw);
        return 1;
    }
    char *path = realpath(raw, NULL);
    free(raw);
    if (!path) {
        perror("OCR launcher: realpath");
        return 1;
    }
    size_t path_len = strlen(path), suffix_len = sizeof(suffix) - 1;
    if (path_len < suffix_len || strcmp(path + path_len - suffix_len, suffix)) {
        fprintf(stderr, "OCR launcher: unexpected executable path: %s\n", path);
        free(path);
        return 1;
    }
    path[path_len - suffix_len] = '\0';
    if (strchr(path, ':')) {
        fprintf(stderr, "OCR launcher: bundle path contains a colon, which dyld cannot represent\n");
        free(path);
        return 1;
    }
    char *worker = NULL, *libraries = NULL;
    if (asprintf(&worker, "%s%s", path, worker_suffix) < 0 ||
        asprintf(&libraries, "%s%s", path, library_suffix) < 0) {
        perror("OCR launcher: asprintf");
        free(worker);
        free(path);
        return 1;
    }
    free(path);
    if (setenv("DYLD_INSERT_LIBRARIES", libraries, 1) != 0) {
        perror("OCR launcher: setenv");
        free(libraries);
        free(worker);
        return 1;
    }
    free(libraries);
    execv(worker, argv);
    perror("OCR launcher: execv worker");
    free(worker);
    return 1;
}
