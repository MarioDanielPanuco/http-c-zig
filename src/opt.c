
#include "../lib/opt.h"

ssize_t opt_parse (int argc, char* argv[]) {
    int opt;
    size_t port;
    int n_threads = DEFAULT_THREAD_COUNT;
    struct OPT opts; 

    while ((opt = getopt(argc, argv, OPTIONS)) != -1) {
        switch (opt) {
        case 't':
            n_threads = atoi(optarg);
            opts.n_threads = n_threads;
            if (n_threads <= 0)
                errx(EXIT_FAILURE, "Initialized with less than zero threads");
            break;
        case 'l':
            opts.log_path = optarg;
            break; 
        default: warnx("Wrong optichar *ons: %s threads", argv[0]); return EXIT_FAILURE;
        }
    }

    if (optind >= argc) {
        errx(EXIT_FAILURE, "wrong number arguments");
    } else {
        char *endptr = NULL;
        port = (size_t) strtoull(argv[optind], &endptr, 10);

        if (endptr && *endptr != '\0') {
            warnx("invalid port number: %s", argv[1]);
            return EXIT_FAILURE;
        }
    }
}

