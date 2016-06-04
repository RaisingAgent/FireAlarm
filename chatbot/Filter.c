//
//  LQDetector.c
//  chatbot
//
//  Created on 5/18/16.
//  Copyright © 2016 NobodyNada. All rights reserved.
//

#include "Filter.h"

Filter *createFilter(const char *desc, const char *filter, FilterType type, unsigned truePositives, unsigned falsePositives) {
    Filter *f = malloc(sizeof(Filter));
    f->desc = malloc(strlen(desc) + 1);
    strcpy(f->desc, desc);
    f->filter = malloc(strlen(filter) + 1);
    strcpy(f->filter, filter);
    
    f->type = type;
    f->truePositives = truePositives;
    f->falsePositives = falsePositives;
    
    int error;
    if (type == FILTER_REGEX && (error = regcomp(&f->regex, f->filter, REG_ICASE))) {
        const unsigned max = 1024;
        char msg[max];
        regerror(error, &f->regex, msg, max);
        fprintf(stderr, "Error compiling regex %s: %s\n", filter, msg);
        exit(EXIT_FAILURE);
    }
    return f;
}

static unsigned char matchRegexFilter(Post *post, Filter *f, unsigned *outStart, unsigned *outEnd) {
    regmatch_t match;
    int error = regexec(&f->regex, post->body, 1, &match, 0);
    if (error == REG_NOMATCH) {
        return 0;
    }
    if (error) {
        const unsigned max = 1024;
        char msg[max];
        regerror(error, &f->regex, msg, max);
        fprintf(stderr, "Error executing regex %s: %s\n", f->filter, msg);
        exit(EXIT_FAILURE);
    }
    if (outStart) *outStart = (unsigned)match.rm_so;
    if (outEnd) *outEnd = (unsigned)match.rm_eo;
    return 1;
}

unsigned char postMatchesFilter(Post *post, Filter *filter, unsigned *outStart, unsigned *outEnd) {
    switch (filter->type) {
        case FILTER_TEXT:
            ;char *start = strstr(post->body, filter->filter);
            if (start) {
                if (outStart) *outStart = (unsigned)(start - post->body);
                if (outEnd) *outEnd = (unsigned)((start - post->body) + strlen(filter->filter));
                return 1;
            }
            return 0;
        case FILTER_REGEX:
            return matchRegexFilter(post, filter, outStart, outEnd);
        case FILTER_SHORTBODY:
            return strlen(post->body) < 500;
        default:
            fprintf(stderr, "Invalid filter type %d\n", filter->type);
            exit(EXIT_FAILURE);
    }
}
