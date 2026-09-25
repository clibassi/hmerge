/*
 * hmerge.c -- hash-join plugin behind hmerge.ado (stata-grouplab prototype).
 *
 * Why this exists: native -merge- sorts the master (O(N log N)) and, unless the
 * using file's stored sort flag matches, loads/sorts/re-saves the using file,
 * only to run a linear merge-join. A hash join needs one pass over each side:
 * build a table on the (unique) using keys, then probe it once per master
 * observation. Master order is preserved; nothing is sorted. Single numeric
 * keys whose using values are integers in a compact range use a direct-
 * address table instead of the hash table (no hashing, one memory access).
 *
 * Protocol (argv[0] selects the step; the ado drives the sequence):
 *
 *   build  <token> <kkeys> <kpay> <uniq> <w_1..w_kkeys> <pw_1..pw_kpay>
 *          Run inside the using frame. varlist = keys then payload vars.
 *          w_k  = 0 for a numeric key, else the common str width used by BOTH
 *                 sides (the ado passes max(master width, using width)).
 *          pw_p = 0 for a numeric payload, else its str width.
 *          Copies keys+payload into plugin memory and builds the hash table.
 *          If <uniq>==1, a duplicate using key is an error (m:1 / 1:1).
 *
 *   match  <token> <kkeys> <kpay> <uniqmaster> <w_1..> <pw_1..>
 *          Run in the master frame. varlist = master keys. Finds each obs's
 *          using row and checks 1:1 uniqueness. Writes NOTHING to the data,
 *          so every validation error leaves the master untouched. Returns
 *          counts in locals hm_n1, hm_n2, hm_n3.
 *
 *   write  <token> <kkeys> <kpay> <w_1..> <pw_1..> <mask_1..>
 *          varlist = master keys, the kpay master TARGET vars (pre-created by
 *          the ado without filling), then the _merge var. Writes payload and
 *          _merge (1 or 3). Targets with mask 0 are pre-existing master vars
 *          (master values win for matched rows) and are skipped; targets with
 *          mask 1 get missing / "" in unmatched rows.
 *
 *   append <token> <kkeys> <kpay> <n0> <w_1..> <pw_1..>
 *          After the ado has run -set obs n0 + nusingonly-, writes the
 *          using-only rows (in key order, as merge does) into obs n0+1.. : keys,
 *          ALL payload vars (overlapping master vars included, as -merge-
 *          does), and _merge = 2.
 *
 *   free   releases the saved state.
 *
 * State persists across plugin calls in static memory. SPI does not document
 * this, so every call after -build- must present the same random <token>; a
 * mismatch (stale state, a different session's call, a reloaded plugin) is
 * refused with rc 459 instead of silently using the wrong table. The ado
 * always calls -free- (also on error, via capture).
 *
 * Key equality is exact byte equality of the packed key row. Numeric keys are
 * stored as the 8 raw bytes of the double Stata hands us, after mapping -0 to
 * +0 so the two compare equal as they do in Stata. Missing values . and .a-.z
 * are distinct doubles, so they are distinct keys, matching -merge-. Hash
 * collisions are resolved by comparing the full key bytes; the hash only
 * chooses the probe sequence.
 */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "stplugin.h"

#define HM_RC_STATE   498   /* state missing / token mismatch (not 459: that is merge's "not unique") */
#define HM_RC_NOTUNIQ 459   /* key does not uniquely identify observations  */
#define HM_RC_OOM     909   /* op. sys. refuses to provide memory           */
#define HM_RC_SYNTAX  198

/* ------------------------------------------------------------------------ */
/* Saved state                                                              */
/* ------------------------------------------------------------------------ */

typedef struct {
    char      token[64];
    int64_t   J;            /* using observations                          */
    int       kkeys, kpay;
    size_t    keybytes;     /* bytes per packed key row                     */
    size_t   *keyoff;       /* offset of key k in the packed row            */
    int      *keyw;         /* 0 numeric, else string width                 */
    unsigned char *keys;    /* J x keybytes                                 */
    int      *payw;         /* 0 numeric, else string width                 */
    size_t   *payoff;       /* offset of payload p in a payload row         */
    size_t    paybytes;
    unsigned char *pay;     /* J x paybytes (doubles and strings, packed)   */
    /* Hash path: open addressing, linear probing. One 8-byte slot per entry:
     * high 32 bits = upper half of the 64-bit hash (a cheap filter before
     * the key memcmp), low 32 bits = using row + 1 (0 = empty). */
    uint64_t *slots;
    uint64_t  capacity;     /* power of two, >= 2J                          */
    /* Direct-address path (single numeric key, all using keys integers in a
     * compact range): dtab[key - dmin] = using row + 1, 0 = absent. No
     * hashing and one memory access per lookup. */
    int       direct;
    double    dmin, dmax;
    uint32_t *dtab;
    unsigned char *matched; /* J flags: using row matched by some master obs */
    int64_t   nusingonly;
    uint32_t *mmatch;       /* per master obs: using row + 1, 0 = no match  */
    int64_t   nmaster;
} hm_state;

static hm_state *S = NULL;

/* Hash seed, drawn once per build step. With a fixed seed an adversarial
 * using file could put every key in one probe chain (quadratic build). */
static uint64_t hm_seed = 0;

static void hm_new_seed(void)
{
#if defined(__APPLE__) || defined(__FreeBSD__) || defined(__OpenBSD__)
    hm_seed = ((uint64_t) arc4random() << 32) | (uint64_t) arc4random();
#else
    hm_seed = (uint64_t) time(NULL) ^ ((uint64_t) (uintptr_t) &hm_seed << 17)
              ^ ((uint64_t) clock() << 32);
#endif
}

static void hm_free(void)
{
    if (S == NULL) return;
    free(S->keyoff);  free(S->keyw);  free(S->keys);
    free(S->payw);    free(S->payoff); free(S->pay);
    free(S->slots); free(S->dtab); free(S->matched); free(S->mmatch);
    free(S);
    S = NULL;
}

/* ------------------------------------------------------------------------ */
/* Hashing: a multiply-xorshift hash over 8-byte words of the packed key.    */
/* Quality only affects speed; equality is always decided by memcmp.         */
/* ------------------------------------------------------------------------ */

static inline uint64_t hm_mix(uint64_t x)
{
    x ^= x >> 30; x *= 0xbf58476d1ce4e5b9ULL;
    x ^= x >> 27; x *= 0x94d049bb133111ebULL;
    x ^= x >> 31;
    return x;
}

static inline uint64_t hm_hash(const unsigned char *p, size_t n)
{
    uint64_t h = 0x9e3779b97f4a7c15ULL ^ hm_seed ^ (uint64_t) n;
    uint64_t w;
    size_t i = 0;
    for (; i + 8 <= n; i += 8) {
        memcpy(&w, p + i, 8);
        h = hm_mix(h ^ w);
    }
    if (i < n) {
        w = 0;
        memcpy(&w, p + i, n - i);
        h = hm_mix(h ^ w);
    }
    return h;
}

/* ------------------------------------------------------------------------ */
/* Reading one observation's key into a packed row                          */
/* ------------------------------------------------------------------------ */

/* Read key vars 1..kkeys of observation obs into row (keybytes, zeroed pad).
 * sbuf must hold max string width + 1 bytes. */
static ST_retcode hm_read_key(ST_int obs, int kkeys, const int *keyw,
                              const size_t *keyoff, size_t keybytes,
                              unsigned char *row, char *sbuf)
{
    ST_retcode rc;
    ST_double z;
    int k;
    memset(row, 0, keybytes);
    for (k = 0; k < kkeys; k++) {
        if (keyw[k] == 0) {
            if ((rc = SF_vdata(k + 1, obs, &z))) return rc;
            if (z == 0.0) z = 0.0;           /* -0 -> +0 */
            memcpy(row + keyoff[k], &z, sizeof z);
        }
        else {
            /* length first: SF_sdata writes the whole value into sbuf */
            if (SF_sdatalen(k + 1, obs) > keyw[k]) return HM_RC_SYNTAX;
            if ((rc = SF_sdata(k + 1, obs, sbuf))) return rc;
            /* strncpy-like: copy up to width, rest already zero */
            size_t len = strlen(sbuf);
            if (len > (size_t) keyw[k]) return HM_RC_SYNTAX;  /* width lie */
            memcpy(row + keyoff[k], sbuf, len);
        }
    }
    return 0;
}

/* Find using row for a packed key, or -1. */
static inline int64_t hm_lookup(const unsigned char *row)
{
    if (S->direct) {
        double z;
        memcpy(&z, row, sizeof z);
        /* missing values are > dmax (using keys are all nonmissing) */
        if (!(z >= S->dmin && z <= S->dmax) || z != (double) (int64_t) z) return -1;
        return (int64_t) S->dtab[(uint64_t) ((int64_t) z - (int64_t) S->dmin)] - 1;
    }
    uint64_t h = hm_hash(row, S->keybytes);
    uint64_t mask = S->capacity - 1, i = h & mask;
    uint32_t tag = (uint32_t) (h >> 32);
    for (;;) {
        uint64_t e = S->slots[i];
        if (e == 0) return -1;
        if ((uint32_t) (e >> 32) == tag) {
            int64_t r = (int64_t) (uint32_t) e - 1;
            if (memcmp(S->keys + (size_t) r * S->keybytes, row, S->keybytes) == 0) return r;
        }
        i = (i + 1) & mask;
    }
}

/* ------------------------------------------------------------------------ */
/* Argument parsing shared by the steps                                     */
/* ------------------------------------------------------------------------ */

static int hm_parse_int(const char *s, long long *out)
{
    char *end;
    long long v = strtoll(s, &end, 10);
    if (*s == '\0' || *end != '\0') return 1;
    *out = v;
    return 0;
}

static int hm_check_token(const char *tok)
{
    if (S == NULL) {
        SF_error("hmerge: no saved join state (build step did not run)\n");
        return HM_RC_STATE;
    }
    if (strcmp(S->token, tok) != 0) {
        SF_error("hmerge: join state belongs to another call; refusing\n");
        return HM_RC_STATE;
    }
    return 0;
}

/* Check that the widths/counts passed to this step match the build step. */
static int hm_check_layout(int kkeys, int kpay, char *argv[], int first)
{
    int k;
    long long v;
    if (kkeys != S->kkeys || kpay != S->kpay) return HM_RC_SYNTAX;
    for (k = 0; k < kkeys; k++) {
        if (hm_parse_int(argv[first + k], &v) || v != S->keyw[k]) return HM_RC_SYNTAX;
    }
    for (k = 0; k < kpay; k++) {
        if (hm_parse_int(argv[first + kkeys + k], &v) || v != S->payw[k]) return HM_RC_SYNTAX;
    }
    return 0;
}

/* ------------------------------------------------------------------------ */
/* build                                                                    */
/* ------------------------------------------------------------------------ */

static ST_retcode hm_build(int argc, char *argv[])
{
    long long kkeys, kpay, uniq, v;
    int k, maxw = 0;
    int64_t J, j;
    ST_retcode rc = 0;
    char *sbuf = NULL;
    ST_double z;

    hm_free();
    hm_new_seed();
    if (argc < 5) return HM_RC_SYNTAX;
    if (hm_parse_int(argv[2], &kkeys) || hm_parse_int(argv[3], &kpay) ||
        hm_parse_int(argv[4], &uniq)) return HM_RC_SYNTAX;
    if (kkeys < 1 || kpay < 0 || argc != 5 + kkeys + kpay) return HM_RC_SYNTAX;
    if (SF_nvars() != kkeys + kpay) return HM_RC_SYNTAX;
    if (strlen(argv[1]) >= sizeof(S->token)) return HM_RC_SYNTAX;

    if ((S = calloc(1, sizeof *S)) == NULL) return HM_RC_OOM;
    strcpy(S->token, argv[1]);
    S->kkeys = (int) kkeys;
    S->kpay  = (int) kpay;
    J = SF_in2() - SF_in1() + 1;
    if (SF_in1() != 1 || J != SF_nobs()) { rc = HM_RC_SYNTAX; goto fail; }
    S->J = J;

    S->keyw   = calloc((size_t) kkeys, sizeof *S->keyw);
    S->keyoff = calloc((size_t) kkeys, sizeof *S->keyoff);
    S->payw   = calloc((size_t) (kpay ? kpay : 1), sizeof *S->payw);
    S->payoff = calloc((size_t) (kpay ? kpay : 1), sizeof *S->payoff);
    if (!S->keyw || !S->keyoff || !S->payw || !S->payoff) { rc = HM_RC_OOM; goto fail; }

    for (k = 0; k < kkeys; k++) {
        if (hm_parse_int(argv[5 + k], &v) || v < 0 || v > 2045) { rc = HM_RC_SYNTAX; goto fail; }
        S->keyw[k]   = (int) v;
        S->keyoff[k] = S->keybytes;
        S->keybytes += v ? (size_t) v : sizeof(ST_double);
        if (v > maxw) maxw = (int) v;
    }
    for (k = 0; k < kpay; k++) {
        if (hm_parse_int(argv[5 + kkeys + k], &v) || v < 0 || v > 2045) { rc = HM_RC_SYNTAX; goto fail; }
        S->payw[k]   = (int) v;
        S->payoff[k] = S->paybytes;
        S->paybytes += v ? (size_t) v : sizeof(ST_double);
        if (v > maxw) maxw = (int) v;
    }

    /* capacity: power of two >= 2J (load factor <= 1/2) */
    S->capacity = 16;
    while (S->capacity < (uint64_t) (2 * (J > 0 ? J : 1))) {
        if (S->capacity > (UINT64_MAX >> 2)) { rc = HM_RC_OOM; goto fail; }
        S->capacity <<= 1;
    }

    if (S->keybytes > 0 && (uint64_t) J > SIZE_MAX / S->keybytes) { rc = HM_RC_OOM; goto fail; }
    if (S->paybytes > 0 && (uint64_t) J > SIZE_MAX / S->paybytes) { rc = HM_RC_OOM; goto fail; }
    if ((uint64_t) J >= UINT32_MAX) {
        SF_error("hmerge: using data has too many observations for this prototype\n");
        rc = HM_RC_OOM; goto fail;
    }
    S->keys      = malloc((size_t) (J ? J : 1) * S->keybytes);
    S->pay       = malloc((size_t) (J ? J : 1) * (S->paybytes ? S->paybytes : 1));
    S->matched   = calloc((size_t) (J ? J : 1), 1);
    sbuf         = malloc((size_t) maxw + 2);
    if (!S->keys || !S->pay || !S->matched || !sbuf) { rc = HM_RC_OOM; goto fail; }

    /* Pass 1: copy keys and payload out of Stata. */
    for (j = 0; j < J; j++) {
        unsigned char *row = S->keys + (size_t) j * S->keybytes;
        unsigned char *prow = S->pay + (size_t) j * S->paybytes;
        if ((rc = hm_read_key((ST_int) (j + 1), S->kkeys, S->keyw, S->keyoff,
                              S->keybytes, row, sbuf))) goto fail;
        for (k = 0; k < S->kpay; k++) {
            if (S->payw[k] == 0) {
                if ((rc = SF_vdata(S->kkeys + k + 1, (ST_int) (j + 1), &z))) goto fail;
                memcpy(prow + S->payoff[k], &z, sizeof z);
            }
            else {
                if (SF_sdatalen(S->kkeys + k + 1, (ST_int) (j + 1)) > S->payw[k]) {
                    rc = HM_RC_SYNTAX; goto fail;
                }
                if ((rc = SF_sdata(S->kkeys + k + 1, (ST_int) (j + 1), sbuf))) goto fail;
                size_t len = strlen(sbuf);
                if (len > (size_t) S->payw[k]) { rc = HM_RC_SYNTAX; goto fail; }
                memset(prow + S->payoff[k], 0, (size_t) S->payw[k]);
                memcpy(prow + S->payoff[k], sbuf, len);
            }
        }
    }

    /* Choose the index. Direct addressing when there is one numeric key and
     * every using key is a nonmissing integer whose range is at most
     * 8J + 1024 slots (4 bytes each): the table then costs at most ~32 bytes
     * per using row, less than the hash table, with no hashing or probing. */
    S->direct = 0;
    if (S->kkeys == 1 && S->keyw[0] == 0 && J > 0) {
        double lo = 0, hi = 0;
        int ok = 1;
        for (j = 0; j < J && ok; j++) {
            memcpy(&z, S->keys + (size_t) j * S->keybytes, sizeof z);
            /* range test first: casting an out-of-range double to int64 is UB */
            if (z != z || SF_is_missing(z) || z > 9.0e15 || z < -9.0e15 || z != (double) (int64_t) z) ok = 0;
            else if (j == 0) lo = hi = z;
            else { if (z < lo) lo = z; if (z > hi) hi = z; }
        }
        if (ok && (hi - lo) <= 8.0 * (double) J + 1024.0) {
            uint64_t R = (uint64_t) ((int64_t) hi - (int64_t) lo) + 1;
            S->dtab = calloc((size_t) R, sizeof *S->dtab);
            if (S->dtab == NULL) { rc = HM_RC_OOM; goto fail; }
            S->direct = 1; S->dmin = lo; S->dmax = hi;
            for (j = 0; j < J; j++) {
                memcpy(&z, S->keys + (size_t) j * S->keybytes, sizeof z);
                uint32_t *slot = &S->dtab[(uint64_t) ((int64_t) z - (int64_t) lo)];
                if (*slot) {
                    if (uniq) {
                        rc = HM_RC_NOTUNIQ; goto fail;
                    }
                    continue;    /* first row wins */
                }
                *slot = (uint32_t) (j + 1);
            }
        }
    }

    if (!S->direct) {
        S->slots = calloc((size_t) S->capacity, sizeof *S->slots);
        if (S->slots == NULL) { rc = HM_RC_OOM; goto fail; }
        for (j = 0; j < J; j++) {
            const unsigned char *row = S->keys + (size_t) j * S->keybytes;
            uint64_t h = hm_hash(row, S->keybytes), mask = S->capacity - 1, i = h & mask;
            uint32_t tag = (uint32_t) (h >> 32);
            for (;;) {
                uint64_t e = S->slots[i];
                if (e == 0) {
                    S->slots[i] = ((uint64_t) tag << 32) | (uint64_t) (j + 1);
                    break;
                }
                if ((uint32_t) (e >> 32) == tag &&
                    memcmp(S->keys + (size_t) ((uint32_t) e - 1) * S->keybytes, row, S->keybytes) == 0) {
                    if (uniq) {
                        rc = HM_RC_NOTUNIQ; goto fail;
                    }
                    break;   /* first row wins */
                }
                i = (i + 1) & mask;
            }
        }
    }
    SF_macro_save("_hm_index", S->direct ? "direct" : "hash");
    free(sbuf);
    return 0;

fail:
    free(sbuf);
    hm_free();
    return rc;
}

/* ------------------------------------------------------------------------ */
/* probe                                                                    */
/* ------------------------------------------------------------------------ */

/* Write payload row r into target vars (positions tgt0+1..). mask[k]==0 skips. */
static ST_retcode hm_write_payload(ST_int obs, int64_t r, int tgt0,
                                   const unsigned char *mask, char *sbuf)
{
    ST_retcode rc;
    ST_double z;
    int k;
    const unsigned char *prow = S->pay + (size_t) r * S->paybytes;
    for (k = 0; k < S->kpay; k++) {
        if (mask && !mask[k]) continue;
        if (S->payw[k] == 0) {
            memcpy(&z, prow + S->payoff[k], sizeof z);
            if ((rc = SF_vstore(tgt0 + k + 1, obs, z))) return rc;
        }
        else {
            memcpy(sbuf, prow + S->payoff[k], (size_t) S->payw[k]);
            sbuf[S->payw[k]] = '\0';
            if ((rc = SF_sstore(tgt0 + k + 1, obs, sbuf))) return rc;
        }
    }
    return 0;
}

static ST_retcode hm_match(int argc, char *argv[])
{
    /* match <token> <kkeys> <kpay> <uniqmaster> <w..> <pw..>
     * varlist = master keys. Reads keys, finds each obs's using row, and
     * validates 1:1 uniqueness. WRITES NOTHING to the dataset, so every
     * validation error leaves the master exactly as it was. */
    long long kkeys, kpay, uniqmaster;
    int k, maxw = 0;
    ST_retcode rc = 0;
    ST_int obs, N = SF_nobs();
    unsigned char *row = NULL;
    char *sbuf = NULL, buf[64];
    int64_t n1 = 0, n3 = 0, r;
    uint64_t mcap = 0, *mslots = NULL;   /* 1:1 only: set of unmatched master keys */
    unsigned char *mkeys = NULL;
    int64_t mused = 0;

    if (argc < 5) return HM_RC_SYNTAX;
    if ((rc = hm_check_token(argv[1]))) return rc;
    if (hm_parse_int(argv[2], &kkeys) || hm_parse_int(argv[3], &kpay) ||
        hm_parse_int(argv[4], &uniqmaster)) return HM_RC_SYNTAX;
    if (argc != 5 + kkeys + kpay) return HM_RC_SYNTAX;
    if ((rc = hm_check_layout((int) kkeys, (int) kpay, argv, 5))) return rc;
    if (SF_nvars() != kkeys) return HM_RC_SYNTAX;
    if (SF_in1() != 1 || SF_in2() != N) return HM_RC_SYNTAX;

    for (k = 0; k < S->kkeys; k++) if (S->keyw[k] > maxw) maxw = S->keyw[k];
    free(S->mmatch);
    S->mmatch = malloc((size_t) (N > 0 ? N : 1) * sizeof *S->mmatch);
    row  = malloc(S->keybytes);
    sbuf = malloc((size_t) maxw + 2);
    if (!S->mmatch || !row || !sbuf) { rc = HM_RC_OOM; goto done; }
    memset(S->matched, 0, (size_t) (S->J ? S->J : 1));
    if (uniqmaster) {
        mcap = 16;
        while (mcap < (uint64_t) (2 * (N > 0 ? N : 1))) mcap <<= 1;
        mslots = calloc((size_t) mcap, sizeof *mslots);
        mkeys  = malloc((size_t) (N > 0 ? N : 1) * S->keybytes);
        if (!mslots || !mkeys) { rc = HM_RC_OOM; goto done; }
    }

    for (obs = 1; obs <= N; obs++) {
        if ((rc = hm_read_key(obs, S->kkeys, S->keyw, S->keyoff, S->keybytes, row, sbuf)))
            goto done;
        r = hm_lookup(row);
        if (r >= 0) {
            if (uniqmaster && S->matched[r]) {
                rc = HM_RC_NOTUNIQ; goto done;
            }
            S->matched[r] = 1;
            S->mmatch[obs - 1] = (uint32_t) (r + 1);
            n3++;
        }
        else {
            if (uniqmaster) {
                /* unmatched master keys must also be unique under 1:1 */
                uint64_t h = hm_hash(row, S->keybytes), m = mcap - 1, i = h & m;
                uint32_t tag = (uint32_t) (h >> 32);
                for (;;) {
                    uint64_t e = mslots[i];
                    if (e == 0) {
                        memcpy(mkeys + (size_t) mused * S->keybytes, row, S->keybytes);
                        mslots[i] = ((uint64_t) tag << 32) | (uint64_t) (++mused);
                        break;
                    }
                    if ((uint32_t) (e >> 32) == tag &&
                        memcmp(mkeys + (size_t) ((uint32_t) e - 1) * S->keybytes, row, S->keybytes) == 0) {
                        rc = HM_RC_NOTUNIQ; goto done;
                    }
                    i = (i + 1) & m;
                }
            }
            S->mmatch[obs - 1] = 0;
            n1++;
        }
    }
    S->nmaster = N;
    S->nusingonly = 0;
    for (r = 0; r < S->J; r++) S->nusingonly += !S->matched[r];

    snprintf(buf, sizeof buf, "%lld", (long long) n1);
    SF_macro_save("_hm_n1", buf);
    snprintf(buf, sizeof buf, "%lld", (long long) n3);
    SF_macro_save("_hm_n3", buf);
    snprintf(buf, sizeof buf, "%lld", (long long) S->nusingonly);
    SF_macro_save("_hm_n2", buf);

done:
    free(row); free(sbuf); free(mslots); free(mkeys);
    if (rc) { free(S->mmatch); S->mmatch = NULL; }
    return rc;
}

static ST_retcode hm_write(int argc, char *argv[])
{
    /* write <token> <kkeys> <kpay> <w..> <pw..> <mask..>
     * varlist = master keys, kpay target vars, merge var. Uses the match
     * results saved by -match-; writes payload into matched rows, missing
     * into new (mask 1) targets of unmatched rows, and _merge 1/3. */
    long long kkeys, kpay, v;
    int k, maxw = 0;
    ST_retcode rc = 0;
    ST_int obs, N = SF_nobs();
    unsigned char *mask = NULL;
    char *sbuf = NULL;

    if (argc < 4) return HM_RC_SYNTAX;
    if ((rc = hm_check_token(argv[1]))) return rc;
    if (hm_parse_int(argv[2], &kkeys) || hm_parse_int(argv[3], &kpay)) return HM_RC_SYNTAX;
    if (argc != 4 + kkeys + 2 * kpay) return HM_RC_SYNTAX;
    if ((rc = hm_check_layout((int) kkeys, (int) kpay, argv, 4))) return rc;
    if (SF_nvars() != kkeys + kpay + 1) return HM_RC_SYNTAX;
    if (S->mmatch == NULL || (int64_t) N != S->nmaster) return HM_RC_STATE;

    for (k = 0; k < S->kpay; k++) if (S->payw[k] > maxw) maxw = S->payw[k];
    sbuf = malloc((size_t) maxw + 2);
    mask = malloc((size_t) (kpay ? kpay : 1));
    if (!sbuf || !mask) { rc = HM_RC_OOM; goto done; }
    for (k = 0; k < kpay; k++) {
        if (hm_parse_int(argv[4 + kkeys + kpay + k], &v) || (v != 0 && v != 1)) {
            rc = HM_RC_SYNTAX; goto done;
        }
        mask[k] = (unsigned char) v;
    }

    for (obs = 1; obs <= N; obs++) {
        uint32_t m = S->mmatch[obs - 1];
        if (m) {
            if ((rc = hm_write_payload(obs, (int64_t) m - 1, S->kkeys, mask, sbuf))) goto done;
            if ((rc = SF_vstore(S->kkeys + S->kpay + 1, obs, 3.0))) goto done;
        }
        else {
            /* New payload vars were created without filling (st_addvar
             * nofill), so unmatched rows must be set to missing here. */
            for (k = 0; k < S->kpay; k++) {
                if (!mask[k]) continue;
                if (S->payw[k] == 0) rc = SF_vstore(S->kkeys + k + 1, obs, SV_missval);
                else                 rc = SF_sstore(S->kkeys + k + 1, obs, "");
                if (rc) goto done;
            }
            if ((rc = SF_vstore(S->kkeys + S->kpay + 1, obs, 1.0))) goto done;
        }
    }

done:
    free(sbuf); free(mask);
    return rc;
}

/* ------------------------------------------------------------------------ */
/* ------------------------------------------------------------------------ */
/* append                                                                   */
/* ------------------------------------------------------------------------ */

/* Order of two packed key rows as Stata's -sort- would put them: key by key,
 * numeric keys as doubles (missing values . < .a < ... < .z are the largest
 * doubles, in that order, so plain comparison is right), string keys by byte
 * (the zero padding makes a prefix sort first). Using keys are unique, so
 * there are no ties to break. */
static int hm_keycmp(const void *a, const void *b)
{
    const unsigned char *ra = S->keys + (size_t) *(const int64_t *) a * S->keybytes;
    const unsigned char *rb = S->keys + (size_t) *(const int64_t *) b * S->keybytes;
    int k, c;
    double za, zb;
    for (k = 0; k < S->kkeys; k++) {
        if (S->keyw[k] == 0) {
            memcpy(&za, ra + S->keyoff[k], sizeof za);
            memcpy(&zb, rb + S->keyoff[k], sizeof zb);
            if (za < zb) return -1;
            if (za > zb) return 1;
            if (za != za || zb != zb) {          /* NaN: sort after numbers */
                if (za == za) return -1;
                if (zb == zb) return 1;
            }
        }
        else {
            c = memcmp(ra + S->keyoff[k], rb + S->keyoff[k], (size_t) S->keyw[k]);
            if (c) return c < 0 ? -1 : 1;
        }
    }
    return 0;
}

static ST_retcode hm_append(int argc, char *argv[])
{
    long long kkeys, kpay, n0;
    int k, maxw = 0;
    ST_retcode rc = 0;
    char *sbuf = NULL;
    int64_t r, i, nord = 0, *order = NULL;
    ST_int obs;
    ST_double z;

    if (argc < 5) return HM_RC_SYNTAX;
    if ((rc = hm_check_token(argv[1]))) return rc;
    if (hm_parse_int(argv[2], &kkeys) || hm_parse_int(argv[3], &kpay) ||
        hm_parse_int(argv[4], &n0) || n0 < 0 || n0 > INT32_MAX) return HM_RC_SYNTAX;
    if (argc != 5 + kkeys + kpay) return HM_RC_SYNTAX;
    if ((rc = hm_check_layout((int) kkeys, (int) kpay, argv, 5))) return rc;
    if (SF_nvars() != kkeys + kpay + 1) return HM_RC_SYNTAX;
    if ((int64_t) SF_nobs() != n0 + S->nusingonly) return HM_RC_SYNTAX;
    if (n0 + S->nusingonly > INT32_MAX) return HM_RC_SYNTAX;   /* ST_int observation index */

    for (k = 0; k < S->kkeys; k++) if (S->keyw[k] > maxw) maxw = S->keyw[k];
    for (k = 0; k < S->kpay; k++)  if (S->payw[k] > maxw) maxw = S->payw[k];
    if ((sbuf = malloc((size_t) maxw + 2)) == NULL) return HM_RC_OOM;

    /* using-only rows, sorted by key: merge returns them in key order */
    order = malloc((size_t) (S->nusingonly ? S->nusingonly : 1) * sizeof *order);
    if (order == NULL) { free(sbuf); return HM_RC_OOM; }
    for (r = 0; r < S->J; r++) if (!S->matched[r]) order[nord++] = r;
    qsort(order, (size_t) nord, sizeof *order, hm_keycmp);

    obs = (ST_int) n0;
    for (i = 0; i < nord; i++) {
        const unsigned char *row;
        r = order[i];
        obs++;
        row = S->keys + (size_t) r * S->keybytes;
        for (k = 0; k < S->kkeys; k++) {
            if (S->keyw[k] == 0) {
                memcpy(&z, row + S->keyoff[k], sizeof z);
                if ((rc = SF_vstore(k + 1, obs, z))) goto done;
            }
            else {
                memcpy(sbuf, row + S->keyoff[k], (size_t) S->keyw[k]);
                sbuf[S->keyw[k]] = '\0';
                if ((rc = SF_sstore(k + 1, obs, sbuf))) goto done;
            }
        }
        if ((rc = hm_write_payload(obs, r, S->kkeys, NULL, sbuf))) goto done;
        if ((rc = SF_vstore(S->kkeys + S->kpay + 1, obs, 2.0))) goto done;
    }

done:
    free(sbuf);
    free(order);
    return rc;
}

/* ------------------------------------------------------------------------ */

STDLL stata_call(int argc, char *argv[])
{
    if (argc < 1) return HM_RC_SYNTAX;
    if (strcmp(argv[0], "build") == 0)  return hm_build(argc, argv);
    if (strcmp(argv[0], "free") == 0)   { hm_free(); return 0; }
    if (strcmp(argv[0], "match") == 0)  return hm_match(argc, argv);
    if (strcmp(argv[0], "write") == 0)  return hm_write(argc, argv);
    if (strcmp(argv[0], "append") == 0) return hm_append(argc, argv);
    return HM_RC_SYNTAX;
}
