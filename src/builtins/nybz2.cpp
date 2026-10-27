// builtins/nybz2.cpp - bzip2, written here (round 83): no system libbz2, so
// every build (Windows/MinGW, 32-bit) has it. Behind lib/bz2.ny; both engines
// (the VM reaches these through the builtin bridge).
//
// The compressor is Seward's algorithm as libbz2 1.0.x implements it, step for
// step, so its output is byte-identical to libbz2's (and so to CPython's
// bz2 module and bzip2(1)) at every compresslevel:
//   - the initial run-length encoding (runs of 4-255 bytes become 4 bytes and
//     a count), carried across block boundaries as libbz2 carries it, blocks
//     cut at 100000 * level - 19 bytes;
//   - the Burrows-Wheeler transform by sorting the block's rotations with
//     libbz2's fallbackSort (Manber-Myers style bucket refinement with the
//     same radix pass, the same three-way quicksort with its pseudo-random
//     pivot and the same small-bucket insertion sort), so even the order of
//     equal rotations (a periodic block) - which decides origPtr - is
//     libbz2's whenever libbz2 sorts with fallbackSort (blocks under 10000
//     bytes, and repetitive blocks, where its mainSort gives up). For other
//     blocks every rotation differs and the sorted order is unique;
//   - move-to-front with the RUNA/RUNB zero-run code, between 2 and 6 Huffman
//     tables chosen by the number of symbols, the initial partition by
//     cumulative frequency, four refinement passes over groups of 50 symbols,
//     code lengths limited to 17 bits by libbz2's weight-halving rule, the
//     selectors move-to-front coded, the code lengths delta coded;
//   - the stream and combined CRCs (CRC-32, MSB first), the bit writer's
//     lazy byte output (so compress() returns what libbz2 has emitted).
// The decompressor reads every bzip2 stream except the long-obsolete
// "randomised" blocks of bzip2 0.9.0 (an error says so); it is resumable at
// any input boundary (a block is decoded once all of it has arrived).
//
//   _bz2_cnew(level) -> h         _bz2_compress(h, data) -> bytes
//   _bz2_flush(h) -> bytes        (finishes the stream)
//   _bz2_dnew() -> h              _bz2_decompress(h, data, max_length) -> [out, eof, unused, needs_input]
//   _bz2_free(h)
#ifndef NYBZ_CORE_ONLY        // (a standalone build of the codec, for testing it against libbz2)
#include "platform_compat.hpp"
#include "NythonExecutor.hpp"
#include "builtins/os.hpp"
#endif
#include <algorithm>
#include <cstring>
#include <memory>
#include <mutex>
#include <unordered_map>

#include <string>
#include <vector>
#include <cstdint>

namespace nybz {

static uint32_t g_crc[256];
static std::once_flag g_once;
static void init_tables() {
    std::call_once(g_once, [] {
        for (uint32_t i = 0; i < 256; i++) {
            uint32_t c = i << 24;
            for (int k = 0; k < 8; k++) c = (c & 0x80000000u) ? (c << 1) ^ 0x04c11db7u : (c << 1);
            g_crc[i] = c;
        }
    });
}
static inline void crc_update(uint32_t& crc, unsigned char ch) { crc = (crc << 8) ^ g_crc[(crc >> 24) ^ ch]; }

struct BzError { std::string msg; };

// ── libbz2's fallbackSort (blocksort.c) ─────────────────────────────────────
#define SET_BH(zz)  bhtab[(zz) >> 5] |= ((uint32_t)1 << ((zz) & 31))
#define CLEAR_BH(zz)  bhtab[(zz) >> 5] &= ~((uint32_t)1 << ((zz) & 31))
#define ISSET_BH(zz)  (bhtab[(zz) >> 5] & ((uint32_t)1 << ((zz) & 31)))
#define WORD_BH(zz)  bhtab[(zz) >> 5]
#define UNALIGNED_BH(zz)  ((zz) & 0x01f)

static void fallbackSimpleSort(uint32_t* fmap, uint32_t* eclass, int32_t lo, int32_t hi) {
    int32_t i, j, tmp;
    uint32_t ec_tmp;
    if (lo == hi) return;
    if (hi - lo > 3) {
        for (i = hi - 4; i >= lo; i--) {
            tmp = (int32_t)fmap[i];
            ec_tmp = eclass[tmp];
            for (j = i + 4; j <= hi && ec_tmp > eclass[fmap[j]]; j += 4) fmap[j - 4] = fmap[j];
            fmap[j - 4] = (uint32_t)tmp;
        }
    }
    for (i = hi - 1; i >= lo; i--) {
        tmp = (int32_t)fmap[i];
        ec_tmp = eclass[tmp];
        for (j = i + 1; j <= hi && ec_tmp > eclass[fmap[j]]; j++) fmap[j - 1] = fmap[j];
        fmap[j - 1] = (uint32_t)tmp;
    }
}

static void fallbackQSort3(uint32_t* fmap, uint32_t* eclass, int32_t loSt, int32_t hiSt) {
    int32_t unLo, unHi, ltLo, gtHi, n, m;
    int32_t lo, hi;
    uint32_t med, r, r3;
    std::vector<int32_t> stLo, stHi;
    r = 0;
    stLo.push_back(loSt); stHi.push_back(hiSt);
    auto fswap = [&](int32_t a, int32_t b) { uint32_t t = fmap[a]; fmap[a] = fmap[b]; fmap[b] = t; };
    auto fvswap = [&](int32_t p1, int32_t p2, int32_t nn) { while (nn > 0) { fswap(p1, p2); p1++; p2++; nn--; } };
    while (!stLo.empty()) {
        lo = stLo.back(); hi = stHi.back(); stLo.pop_back(); stHi.pop_back();
        if (hi - lo < 10) { fallbackSimpleSort(fmap, eclass, lo, hi); continue; }
        r = ((r * 7621) + 1) % 32768;
        r3 = r % 3;
        if (r3 == 0) med = eclass[fmap[lo]];
        else if (r3 == 1) med = eclass[fmap[(lo + hi) >> 1]];
        else med = eclass[fmap[hi]];
        unLo = ltLo = lo;
        unHi = gtHi = hi;
        while (1) {
            while (1) {
                if (unLo > unHi) break;
                n = (int32_t)eclass[fmap[unLo]] - (int32_t)med;
                if (n == 0) { fswap(unLo, ltLo); ltLo++; unLo++; continue; }
                if (n > 0) break;
                unLo++;
            }
            while (1) {
                if (unLo > unHi) break;
                n = (int32_t)eclass[fmap[unHi]] - (int32_t)med;
                if (n == 0) { fswap(unHi, gtHi); gtHi--; unHi--; continue; }
                if (n < 0) break;
                unHi--;
            }
            if (unLo > unHi) break;
            fswap(unLo, unHi); unLo++; unHi--;
        }
        if (gtHi < ltLo) continue;
        n = std::min(ltLo - lo, unLo - ltLo); fvswap(lo, unLo - n, n);
        m = std::min(hi - gtHi, gtHi - unHi); fvswap(unLo, hi - m + 1, m);
        n = lo + unLo - ltLo - 1;
        m = hi - (gtHi - unHi) + 1;
        if (n - lo > hi - m) {
            stLo.push_back(lo); stHi.push_back(n);
            stLo.push_back(m); stHi.push_back(hi);
        } else {
            stLo.push_back(m); stHi.push_back(hi);
            stLo.push_back(lo); stHi.push_back(n);
        }
    }
}

// fmap: out (the sorted rotations); block: the block's bytes
static void fallbackSort(uint32_t* fmap, const unsigned char* block, int32_t nblock) {
    int32_t ftab[257], ftabCopy[256];
    int32_t H, i, j, k, l, r, cc, cc1, nNotDone, nBhtab;
    std::vector<uint32_t> eclassv((size_t)nblock + 1);
    uint32_t* eclass = eclassv.data();
    nBhtab = 2 + (nblock / 32);
    std::vector<uint32_t> bhv((size_t)nBhtab + 4, 0);
    uint32_t* bhtab = bhv.data();
    for (i = 0; i < 257; i++) ftab[i] = 0;
    for (i = 0; i < nblock; i++) ftab[block[i]]++;
    for (i = 0; i < 256; i++) ftabCopy[i] = ftab[i];
    (void)ftabCopy;
    for (i = 1; i < 257; i++) ftab[i] += ftab[i - 1];
    for (i = 0; i < nblock; i++) {
        j = block[i];
        k = ftab[j] - 1;
        ftab[j] = k;
        fmap[k] = (uint32_t)i;
    }
    for (i = 0; i < nBhtab; i++) bhtab[i] = 0;
    for (i = 0; i < 256; i++) SET_BH(ftab[i]);
    for (i = 0; i < 32; i++) { SET_BH(nblock + 2 * i); CLEAR_BH(nblock + 2 * i + 1); }
    H = 1;
    while (1) {
        j = 0;
        for (i = 0; i < nblock; i++) {
            if (ISSET_BH(i)) j = i;
            k = (int32_t)fmap[i] - H; if (k < 0) k += nblock;
            eclass[k] = (uint32_t)j;
        }
        nNotDone = 0;
        r = -1;
        while (1) {
            k = r + 1;
            while (ISSET_BH(k) && UNALIGNED_BH(k)) k++;
            if (ISSET_BH(k)) {
                while (WORD_BH(k) == 0xffffffff) k += 32;
                while (ISSET_BH(k)) k++;
            }
            l = k - 1;
            if (l >= nblock) break;
            while (!ISSET_BH(k) && UNALIGNED_BH(k)) k++;
            if (!ISSET_BH(k)) {
                while (WORD_BH(k) == 0x00000000) k += 32;
                while (!ISSET_BH(k)) k++;
            }
            r = k - 1;
            if (r >= nblock) break;
            if (r > l) {
                nNotDone += (r - l + 1);
                fallbackQSort3(fmap, eclass, l, r);
                cc = -1;
                for (i = l; i <= r; i++) {
                    cc1 = (int32_t)eclass[fmap[i]];
                    if (cc != cc1) { SET_BH(i); cc = cc1; }
                }
            }
        }
        H *= 2;
        if (H > nblock || nNotDone == 0) break;
    }
}
#undef SET_BH
#undef CLEAR_BH
#undef ISSET_BH
#undef WORD_BH
#undef UNALIGNED_BH

// ── Huffman code lengths (huffman.c) ────────────────────────────────────────
static void hbMakeCodeLengths(unsigned char* len, const int32_t* freq, int32_t alphaSize, int32_t maxLen) {
    int32_t nNodes, nHeap, n1, n2, i, j, k;
    bool tooLong;
    int32_t heap[260 + 2];
    int32_t weight[260 * 2];
    int32_t parent[260 * 2];
    auto WEIGHTOF = [](int32_t z) { return z & (int32_t)0xffffff00; };
    auto DEPTHOF = [](int32_t z) { return z & 0x000000ff; };
    for (i = 0; i < alphaSize; i++) weight[i + 1] = (freq[i] == 0 ? 1 : freq[i]) << 8;
    while (true) {
        nNodes = alphaSize;
        nHeap = 0;
        heap[0] = 0; weight[0] = 0; parent[0] = -2;
        auto upheap = [&](int32_t z) {
            int32_t zz = z, tmp = heap[zz];
            while (weight[tmp] < weight[heap[zz >> 1]]) { heap[zz] = heap[zz >> 1]; zz >>= 1; }
            heap[zz] = tmp;
        };
        auto downheap = [&](int32_t z) {
            int32_t zz = z, yy, tmp = heap[zz];
            while (true) {
                yy = zz << 1;
                if (yy > nHeap) break;
                if (yy < nHeap && weight[heap[yy + 1]] < weight[heap[yy]]) yy++;
                if (weight[tmp] < weight[heap[yy]]) break;
                heap[zz] = heap[yy];
                zz = yy;
            }
            heap[zz] = tmp;
        };
        for (i = 1; i <= alphaSize; i++) { parent[i] = -1; nHeap++; heap[nHeap] = i; upheap(nHeap); }
        while (nHeap > 1) {
            n1 = heap[1]; heap[1] = heap[nHeap]; nHeap--; downheap(1);
            n2 = heap[1]; heap[1] = heap[nHeap]; nHeap--; downheap(1);
            nNodes++;
            parent[n1] = parent[n2] = nNodes;
            int32_t w1 = weight[n1], w2 = weight[n2];
            weight[nNodes] = (WEIGHTOF(w1) + WEIGHTOF(w2)) | (1 + std::max(DEPTHOF(w1), DEPTHOF(w2)));
            parent[nNodes] = -1;
            nHeap++;
            heap[nHeap] = nNodes;
            upheap(nHeap);
        }
        tooLong = false;
        for (i = 1; i <= alphaSize; i++) {
            j = 0; k = i;
            while (parent[k] >= 0) { k = parent[k]; j++; }
            len[i - 1] = (unsigned char)j;
            if (j > maxLen) tooLong = true;
        }
        if (!tooLong) break;
        for (i = 1; i <= alphaSize; i++) {
            j = weight[i] >> 8;
            j = 1 + (j / 2);
            weight[i] = j << 8;
        }
    }
}

static void hbAssignCodes(int32_t* code, const unsigned char* length, int32_t minLen, int32_t maxLen, int32_t alphaSize) {
    int32_t vec = 0;
    for (int32_t n = minLen; n <= maxLen; n++) {
        for (int32_t i = 0; i < alphaSize; i++)
            if (length[i] == n) { code[i] = vec; vec++; }
        vec <<= 1;
    }
}

// ── the compressor ──────────────────────────────────────────────────────────
struct Compressor {
    int level = 9;
    int32_t nblockMAX = 0;
    std::vector<unsigned char> block;
    int32_t nblock = 0;
    bool inUse[256];
    uint32_t state_in_ch = 256;
    int32_t state_in_len = 0;
    uint32_t blockCRC = 0xffffffffu, combinedCRC = 0;
    int blockNo = 1;
    bool finished = false;
    // bit writer (libbz2's: bytes leave the buffer lazily)
    uint32_t bsBuff = 0;
    int32_t bsLive = 0;
    std::string out;

    void init(int lvl) {
        init_tables();
        level = lvl;
        nblockMAX = 100000 * lvl - 19;
        block.resize((size_t)100000 * lvl + 32);
        prepare_new_block();
        blockNo = 1;
    }
    void prepare_new_block() {
        nblock = 0;
        blockCRC = 0xffffffffu;
        std::memset(inUse, 0, sizeof inUse);
    }
    void bsW(int32_t n, uint32_t v) {
        while (bsLive >= 8) { out.push_back((char)(bsBuff >> 24)); bsBuff <<= 8; bsLive -= 8; }
        bsBuff |= (v << (32 - bsLive - n));
        bsLive += n;
    }
    void bsPutUChar(unsigned char c) { bsW(8, c); }
    void bsPutUInt32(uint32_t u) {
        bsW(8, (u >> 24) & 0xff); bsW(8, (u >> 16) & 0xff); bsW(8, (u >> 8) & 0xff); bsW(8, u & 0xff);
    }
    void bsFinishWrite() {
        while (bsLive > 0) { out.push_back((char)(bsBuff >> 24)); bsBuff <<= 8; bsLive -= 8; }
    }
    void add_pair_to_block() {
        unsigned char ch = (unsigned char)state_in_ch;
        for (int32_t i = 0; i < state_in_len; i++) crc_update(blockCRC, ch);
        inUse[state_in_ch] = true;
        switch (state_in_len) {
        case 1: block[nblock++] = ch; break;
        case 2: block[nblock++] = ch; block[nblock++] = ch; break;
        case 3: block[nblock++] = ch; block[nblock++] = ch; block[nblock++] = ch; break;
        default:
            inUse[state_in_len - 4] = true;
            block[nblock++] = ch; block[nblock++] = ch; block[nblock++] = ch; block[nblock++] = ch;
            block[nblock++] = (unsigned char)(state_in_len - 4);
            break;
        }
    }
    void flush_RL() {
        if (state_in_ch < 256) add_pair_to_block();
        state_in_ch = 256; state_in_len = 0;
    }
    inline void add_char(uint32_t zchh) {
        if (zchh != state_in_ch && state_in_len == 1) {
            unsigned char ch = (unsigned char)state_in_ch;
            crc_update(blockCRC, ch);
            inUse[state_in_ch] = true;
            block[nblock++] = ch;
            state_in_ch = zchh;
        } else if (zchh != state_in_ch || state_in_len == 255) {
            if (state_in_ch < 256) add_pair_to_block();
            state_in_ch = zchh;
            state_in_len = 1;
        } else {
            state_in_len++;
        }
    }
    void feed(const unsigned char* p, size_t n) {
        size_t i = 0;
        while (i < n) {
            while (i < n && nblock < nblockMAX) add_char(p[i++]);
            if (nblock >= nblockMAX) { compressBlock(false); prepare_new_block(); blockNo++; }
        }
    }
    void finish() {
        flush_RL();
        compressBlock(true);
        finished = true;
    }

    void compressBlock(bool last) {
        uint32_t origPtr = 0;
        std::vector<uint32_t> ptr;
        if (nblock > 0) {
            blockCRC = ~blockCRC;
            combinedCRC = (combinedCRC << 1) | (combinedCRC >> 31);
            combinedCRC ^= blockCRC;
            ptr.resize((size_t)nblock);
            fallbackSort(ptr.data(), block.data(), nblock);
            for (int32_t i = 0; i < nblock; i++) if (ptr[i] == 0) { origPtr = (uint32_t)i; break; }
        }
        if (blockNo == 1) {
            bsPutUChar('B'); bsPutUChar('Z'); bsPutUChar('h'); bsPutUChar((unsigned char)('0' + level));
        }
        if (nblock > 0) {
            bsPutUChar(0x31); bsPutUChar(0x41); bsPutUChar(0x59); bsPutUChar(0x26); bsPutUChar(0x53); bsPutUChar(0x59);
            bsPutUInt32(blockCRC);
            bsW(1, 0);
            bsW(24, origPtr);
            std::vector<uint16_t> mtfv;
            int32_t mtfFreq[258];
            int32_t nInUse = 0;
            unsigned char unseqToSeq[256];
            generateMTF(ptr, mtfv, mtfFreq, nInUse, unseqToSeq);
            sendMTF(mtfv, mtfFreq, nInUse);
        }
        if (last) {
            bsPutUChar(0x17); bsPutUChar(0x72); bsPutUChar(0x45); bsPutUChar(0x38); bsPutUChar(0x50); bsPutUChar(0x90);
            bsPutUInt32(combinedCRC);
            bsFinishWrite();
        }
    }

    void generateMTF(const std::vector<uint32_t>& ptr, std::vector<uint16_t>& mtfv, int32_t* mtfFreq,
                     int32_t& nInUse, unsigned char* unseqToSeq) {
        unsigned char yy[256];
        nInUse = 0;
        for (int i = 0; i < 256; i++) if (inUse[i]) unseqToSeq[i] = (unsigned char)nInUse++;
        int32_t EOB = nInUse + 1;
        for (int32_t i = 0; i <= EOB; i++) mtfFreq[i] = 0;
        int32_t zPend = 0;
        for (int32_t i = 0; i < nInUse; i++) yy[i] = (unsigned char)i;
        mtfv.reserve((size_t)nblock + 1);
        auto flush_run = [&]() {
            zPend--;
            while (true) {
                if (zPend & 1) { mtfv.push_back(1); mtfFreq[1]++; }
                else { mtfv.push_back(0); mtfFreq[0]++; }
                if (zPend < 2) break;
                zPend = (zPend - 2) / 2;
            }
            zPend = 0;
        };
        for (int32_t i = 0; i < nblock; i++) {
            int32_t j = (int32_t)ptr[i] - 1; if (j < 0) j += nblock;
            unsigned char ll_i = unseqToSeq[block[j]];
            if (yy[0] == ll_i) { zPend++; continue; }
            if (zPend > 0) flush_run();
            unsigned char rtmp = yy[1];
            yy[1] = yy[0];
            unsigned char* ryy_j = &yy[1];
            while (ll_i != rtmp) {
                ryy_j++;
                unsigned char rtmp2 = rtmp;
                rtmp = *ryy_j;
                *ryy_j = rtmp2;
            }
            yy[0] = rtmp;
            int32_t jj = (int32_t)(ryy_j - &yy[0]);
            mtfv.push_back((uint16_t)(jj + 1)); mtfFreq[jj + 1]++;
        }
        if (zPend > 0) flush_run();
        mtfv.push_back((uint16_t)EOB); mtfFreq[EOB]++;
    }

    void sendMTF(const std::vector<uint16_t>& mtfv, const int32_t* mtfFreq, int32_t nInUse) {
        const int N_GROUPS = 6, G_SIZE = 50, N_ITERS = 4;
        int32_t nMTF = (int32_t)mtfv.size();
        int32_t alphaSize = nInUse + 2;
        unsigned char len[N_GROUPS][258];
        int32_t code[N_GROUPS][258];
        int32_t rfreq[N_GROUPS][258];
        for (int t = 0; t < N_GROUPS; t++) for (int v = 0; v < alphaSize; v++) len[t][v] = 15;
        int nGroups = nMTF < 200 ? 2 : nMTF < 600 ? 3 : nMTF < 1200 ? 4 : nMTF < 2400 ? 5 : 6;
        {
            int32_t nPart = nGroups, remF = nMTF, gs = 0, ge, tFreq, aFreq;
            while (nPart > 0) {
                tFreq = remF / nPart;
                ge = gs - 1;
                aFreq = 0;
                while (aFreq < tFreq && ge < alphaSize - 1) { ge++; aFreq += mtfFreq[ge]; }
                if (ge > gs && nPart != nGroups && nPart != 1 && ((nGroups - nPart) % 2 == 1)) {
                    aFreq -= mtfFreq[ge];
                    ge--;
                }
                for (int32_t v = 0; v < alphaSize; v++) len[nPart - 1][v] = (v >= gs && v <= ge) ? 0 : 15;
                nPart--;
                gs = ge + 1;
                remF -= aFreq;
            }
        }
        std::vector<unsigned char> selector;
        for (int iter = 0; iter < N_ITERS; iter++) {
            for (int t = 0; t < nGroups; t++) for (int v = 0; v < alphaSize; v++) rfreq[t][v] = 0;
            selector.clear();
            int32_t gs = 0;
            while (gs < nMTF) {
                int32_t ge = gs + G_SIZE - 1;
                if (ge >= nMTF) ge = nMTF - 1;
                uint16_t cost[N_GROUPS] = {0, 0, 0, 0, 0, 0};
                for (int32_t i = gs; i <= ge; i++) {
                    uint16_t icv = mtfv[i];
                    for (int t = 0; t < nGroups; t++) cost[t] = (uint16_t)(cost[t] + len[t][icv]);
                }
                int32_t bc = 999999999, bt = -1;
                for (int t = 0; t < nGroups; t++) if (cost[t] < bc) { bc = cost[t]; bt = t; }
                selector.push_back((unsigned char)bt);
                for (int32_t i = gs; i <= ge; i++) rfreq[bt][mtfv[i]]++;
                gs = ge + 1;
            }
            for (int t = 0; t < nGroups; t++) hbMakeCodeLengths(&len[t][0], &rfreq[t][0], alphaSize, 17);
        }
        int32_t nSelectors = (int32_t)selector.size();
        std::vector<unsigned char> selectorMtf((size_t)nSelectors);
        {
            unsigned char pos[N_GROUPS], ll_i, tmp2, tmp;
            for (int i = 0; i < nGroups; i++) pos[i] = (unsigned char)i;
            for (int32_t i = 0; i < nSelectors; i++) {
                ll_i = selector[i];
                int j = 0;
                tmp = pos[j];
                while (ll_i != tmp) { j++; tmp2 = tmp; tmp = pos[j]; pos[j] = tmp2; }
                pos[0] = tmp;
                selectorMtf[i] = (unsigned char)j;
            }
        }
        for (int t = 0; t < nGroups; t++) {
            int32_t minLen = 32, maxLen = 0;
            for (int32_t i = 0; i < alphaSize; i++) {
                if (len[t][i] > maxLen) maxLen = len[t][i];
                if (len[t][i] < minLen) minLen = len[t][i];
            }
            hbAssignCodes(&code[t][0], &len[t][0], minLen, maxLen, alphaSize);
        }
        {
            bool inUse16[16];
            for (int i = 0; i < 16; i++) {
                inUse16[i] = false;
                for (int j = 0; j < 16; j++) if (inUse[i * 16 + j]) inUse16[i] = true;
            }
            for (int i = 0; i < 16; i++) bsW(1, inUse16[i] ? 1 : 0);
            for (int i = 0; i < 16; i++)
                if (inUse16[i]) for (int j = 0; j < 16; j++) bsW(1, inUse[i * 16 + j] ? 1 : 0);
        }
        bsW(3, (uint32_t)nGroups);
        bsW(15, (uint32_t)nSelectors);
        for (int32_t i = 0; i < nSelectors; i++) {
            for (int j = 0; j < selectorMtf[i]; j++) bsW(1, 1);
            bsW(1, 0);
        }
        for (int t = 0; t < nGroups; t++) {
            int32_t curr = len[t][0];
            bsW(5, (uint32_t)curr);
            for (int32_t i = 0; i < alphaSize; i++) {
                while (curr < len[t][i]) { bsW(2, 2); curr++; }
                while (curr > len[t][i]) { bsW(2, 3); curr--; }
                bsW(1, 0);
            }
        }
        int32_t selCtr = 0, gs = 0;
        while (gs < nMTF) {
            int32_t ge = gs + G_SIZE - 1;
            if (ge >= nMTF) ge = nMTF - 1;
            int t = selector[selCtr];
            for (int32_t i = gs; i <= ge; i++) bsW(len[t][mtfv[i]], (uint32_t)code[t][mtfv[i]]);
            gs = ge + 1;
            selCtr++;
        }
    }
};

// ── the decompressor ────────────────────────────────────────────────────────
struct BitReader {
    const unsigned char* p;
    size_t n;
    size_t bitpos = 0;     // bits consumed
    struct Short {};
    uint32_t get(int k) {
        uint32_t v = 0;
        for (int i = 0; i < k; i++) {
            size_t byte = bitpos >> 3;
            if (byte >= n) throw Short();
            v = (v << 1) | ((p[byte] >> (7 - (bitpos & 7))) & 1);
            bitpos++;
        }
        return v;
    }
    uint32_t bit() {
        size_t byte = bitpos >> 3;
        if (byte >= n) throw Short();
        uint32_t v = (p[byte] >> (7 - (bitpos & 7))) & 1;
        bitpos++;
        return v;
    }
};

struct Decompressor {
    enum State { HEADER, BLOCKS, DONE } st = HEADER;
    std::string in;            // input not yet consumed
    size_t bitpos = 0;         // bits of `in` consumed (whole blocks only)
    int level = 0;
    uint32_t combinedCRC = 0;
    std::string pending;       // decoded, not yet returned
    std::string unused;
    bool eof = false;

    // Decode as much as the buffered input allows (whole blocks).
    void run() {
        init_tables();
        while (st != DONE) {
            BitReader br{(const unsigned char*)in.data(), in.size(), bitpos};
            try {
                if (st == HEADER) {
                    if (br.get(8) != 'B' || br.get(8) != 'Z' || br.get(8) != 'h') throw BzError{"Invalid data stream"};
                    uint32_t l = br.get(8);
                    if (l < '1' || l > '9') throw BzError{"Invalid data stream"};
                    level = (int)(l - '0');
                    bitpos = br.bitpos;
                    st = BLOCKS;
                    continue;
                }
                uint64_t magic = ((uint64_t)br.get(24) << 24) | br.get(24);
                if (magic == 0x177245385090ULL) {
                    uint32_t crc = br.get(32);
                    if (crc != combinedCRC) throw BzError{"Invalid data stream"};
                    size_t used = (br.bitpos + 7) >> 3;
                    unused = in.substr(used);
                    in.clear();
                    bitpos = 0;
                    st = DONE;
                    eof = true;
                    break;
                }
                if (magic != 0x314159265359ULL) throw BzError{"Invalid data stream"};
                std::string blk;
                decode_block(br, blk);
                pending += blk;
                bitpos = br.bitpos;
                // drop whole consumed bytes
                size_t drop = bitpos >> 3;
                if (drop > 65536) { in.erase(0, drop); bitpos -= drop * 8; }
            } catch (BitReader::Short&) {
                return;   // wait for more input
            }
        }
    }

    void decode_block(BitReader& br, std::string& outb) {
        uint32_t blockCRC = br.get(32);
        if (br.bit()) throw BzError{"Invalid data stream (randomised blocks of bzip2 0.9.0 are not supported)"};
        int32_t origPtr = (int32_t)br.get(24);
        int32_t blockMax = 100000 * level;
        if (origPtr < 0 || origPtr > 10 + blockMax) throw BzError{"Invalid data stream"};
        bool inUse[256] = {false};
        uint32_t used16 = br.get(16);
        for (int i = 0; i < 16; i++)
            if (used16 & (0x8000u >> i))
                for (int j = 0; j < 16; j++) if (br.bit()) inUse[i * 16 + j] = true;
        unsigned char seqToUnseq[256];
        int nInUse = 0;
        for (int i = 0; i < 256; i++) if (inUse[i]) seqToUnseq[nInUse++] = (unsigned char)i;
        if (nInUse == 0) throw BzError{"Invalid data stream"};
        int alphaSize = nInUse + 2;
        int nGroups = (int)br.get(3);
        if (nGroups < 2 || nGroups > 6) throw BzError{"Invalid data stream"};
        int32_t nSelectors = (int32_t)br.get(15);
        if (nSelectors < 1) throw BzError{"Invalid data stream"};
        std::vector<unsigned char> selMtf;
        selMtf.reserve(std::min<int32_t>(nSelectors, 18002));
        for (int32_t i = 0; i < nSelectors; i++) {
            int j = 0;
            while (br.bit()) { j++; if (j >= nGroups) throw BzError{"Invalid data stream"}; }
            if (i < 18002) selMtf.push_back((unsigned char)j);
        }
        if (nSelectors > 18002) nSelectors = 18002;
        std::vector<unsigned char> selector((size_t)nSelectors);
        {
            unsigned char pos[6];
            for (int v = 0; v < nGroups; v++) pos[v] = (unsigned char)v;
            for (int32_t i = 0; i < nSelectors; i++) {
                int v = selMtf[i];
                unsigned char tmp = pos[v];
                while (v > 0) { pos[v] = pos[v - 1]; v--; }
                pos[0] = tmp;
                selector[i] = tmp;
            }
        }
        unsigned char len[6][258];
        for (int t = 0; t < nGroups; t++) {
            int curr = (int)br.get(5);
            for (int i = 0; i < alphaSize; i++) {
                while (true) {
                    if (curr < 1 || curr > 20) throw BzError{"Invalid data stream"};
                    if (!br.bit()) break;
                    if (!br.bit()) curr++; else curr--;
                }
                len[t][i] = (unsigned char)curr;
            }
        }
        // canonical decoding tables (libbz2's hbCreateDecodeTables)
        int32_t limit[6][23], base[6][23], perm[6][258], minLens[6];
        for (int t = 0; t < nGroups; t++) {
            int minLen = 32, maxLen = 0;
            for (int i = 0; i < alphaSize; i++) { minLen = std::min<int>(minLen, len[t][i]); maxLen = std::max<int>(maxLen, len[t][i]); }
            int pp = 0;
            for (int i = minLen; i <= maxLen; i++)
                for (int j = 0; j < alphaSize; j++) if (len[t][j] == i) perm[t][pp++] = j;
            int32_t* b = base[t];
            int32_t* lim = limit[t];
            for (int i = 0; i < 23; i++) { b[i] = 0; lim[i] = 0; }
            for (int i = 0; i < alphaSize; i++) b[len[t][i] + 1]++;
            for (int i = 1; i < 23; i++) b[i] += b[i - 1];
            int32_t vec = 0;
            for (int i = minLen; i <= maxLen; i++) {
                vec += (b[i + 1] - b[i]);
                lim[i] = vec - 1;
                vec <<= 1;
            }
            for (int i = minLen + 1; i <= maxLen; i++) b[i] = ((lim[i - 1] + 1) << 1) - b[i];
            minLens[t] = minLen;
        }
        // MTF / RLE2 decoding
        int32_t EOB = nInUse + 1;
        std::vector<uint32_t> tt;
        tt.reserve((size_t)blockMax);
        int32_t unzftab[256] = {0};
        unsigned char yy[256];
        for (int i = 0; i < 256; i++) yy[i] = (unsigned char)i;
        int32_t groupNo = -1, groupPos = 0;
        int gSel = 0;
        int32_t es = -1, N = 1;
        auto next_sym = [&]() -> int32_t {
            if (groupPos == 0) {
                groupNo++;
                if (groupNo >= nSelectors) throw BzError{"Invalid data stream"};
                groupPos = 50;
                gSel = selector[groupNo];
            }
            groupPos--;
            int zn = minLens[gSel];
            int32_t zvec = (int32_t)br.get(zn);
            while (true) {
                if (zn > 20) throw BzError{"Invalid data stream"};
                if (zvec <= limit[gSel][zn]) break;
                zn++;
                zvec = (zvec << 1) | (int32_t)br.bit();
            }
            int32_t idx = zvec - base[gSel][zn];
            if (idx < 0 || idx >= 258) throw BzError{"Invalid data stream"};
            return perm[gSel][idx];
        };
        int32_t nextSym = next_sym();
        while (true) {
            if (nextSym == EOB) break;
            if (nextSym == 0 || nextSym == 1) {
                es = -1; N = 1;
                do {
                    if (N >= 2 * 1024 * 1024) throw BzError{"Invalid data stream"};
                    if (nextSym == 0) es += N; else es += 2 * N;
                    N *= 2;
                    nextSym = next_sym();
                } while (nextSym == 0 || nextSym == 1);
                es++;
                unsigned char uc = seqToUnseq[yy[0]];
                unzftab[uc] += es;
                if ((int64_t)tt.size() + es > blockMax) throw BzError{"Invalid data stream"};
                tt.insert(tt.end(), (size_t)es, uc);
                continue;
            }
            if ((int32_t)tt.size() >= blockMax) throw BzError{"Invalid data stream"};
            int nn = nextSym - 1;
            if (nn >= nInUse) throw BzError{"Invalid data stream"};
            unsigned char v = yy[nn];
            std::memmove(&yy[1], &yy[0], (size_t)nn);
            yy[0] = v;
            unsigned char uc = seqToUnseq[v];
            unzftab[uc]++;
            tt.push_back(uc);
            nextSym = next_sym();
        }
        int32_t nblock = (int32_t)tt.size();
        if (origPtr < 0 || origPtr >= nblock) throw BzError{"Invalid data stream"};
        // inverse BWT (libbz2's fast path: tt[cftab[ll]++] |= i << 8)
        int32_t cftab[257];
        cftab[0] = 0;
        for (int i = 1; i <= 256; i++) cftab[i] = unzftab[i - 1];
        for (int i = 1; i <= 256; i++) cftab[i] += cftab[i - 1];
        for (int32_t i = 0; i < nblock; i++) {
            unsigned char uc = (unsigned char)(tt[i] & 0xff);
            tt[cftab[uc]] |= ((uint32_t)i << 8);
            cftab[uc]++;
        }
        uint32_t tPos = tt[origPtr] >> 8;
        // undo the initial run-length coding while walking the chain
        uint32_t crc = 0xffffffffu;
        outb.reserve(outb.size() + (size_t)nblock);
        int32_t k0 = -1, run = 0;
        for (int32_t i = 0; i < nblock; i++) {
            tPos = tt[tPos];
            unsigned char ch = (unsigned char)(tPos & 0xff);
            tPos >>= 8;
            if (run == 4) {
                for (int r = 0; r < ch; r++) { outb.push_back((char)k0); crc_update(crc, (unsigned char)k0); }
                run = 0;
                k0 = -1;
                continue;
            }
            if (ch == k0) run++;
            else { run = 1; k0 = ch; }
            outb.push_back((char)ch);
            crc_update(crc, ch);
        }
        crc = ~crc;
        if (crc != blockCRC) throw BzError{"Invalid data stream"};
        combinedCRC = ((combinedCRC << 1) | (combinedCRC >> 31)) ^ blockCRC;
    }
};

struct Obj {
    bool is_c = true;
    Compressor c;
    Decompressor d;
};
std::mutex& mu() { static std::mutex m; return m; }
std::unordered_map<int64_t, std::unique_ptr<Obj>>& table() {
    static auto* t = new std::unordered_map<int64_t, std::unique_ptr<Obj>>();
    return *t;
}
int64_t g_next = 1;

} // namespace nybz

#ifndef NYBZ_CORE_ONLY
Value dispatch_bz2(NythonExecutor& E, const std::string& name, std::vector<Value>& args, Context* ctx);
std::vector<std::string> bz2_builtin_names();

namespace {
[[noreturn]] void fail(const std::string& type, const std::string& msg) { nyos::raise(type, msg); }
std::string bytes_arg(NythonExecutor& E, const Value& v) {
    if (auto* bo = E.bytesOf(v)) return bo->s;
    fail("TypeError", "a bytes-like object is required, not '" + E.typeNameOf(v) + "'");
}
int64_t int_arg(const Value& v) {
    if (v.type == ValueType::INTEGER || v.type == ValueType::BOOLEAN) return (int64_t)nyos::to_int(v, 0);
    fail("TypeError", "an integer is required");
}
nybz::Obj* get(int64_t h) {
    auto it = nybz::table().find(h);
    if (it == nybz::table().end()) fail("ValueError", "invalid bz2 object");
    return it->second.get();
}
} // namespace

std::vector<std::string> bz2_builtin_names() {
    return {"_bz2_cnew", "_bz2_compress", "_bz2_flush", "_bz2_dnew", "_bz2_decompress", "_bz2_free"};
}

Value dispatch_bz2(NythonExecutor& E, const std::string& name, std::vector<Value>& args, Context* ctx) {
    (void)ctx;
    if (name.compare(0, 5, "_bz2_") != 0) return UNDEFINED_VALUE;
    auto arg = [&](size_t i) -> const Value& {
        if (i >= args.size()) fail("TypeError", name + "(): missing argument");
        return args[i];
    };
    if (name == "_bz2_cnew") {
        int64_t level = int_arg(arg(0));
        if (level < 1 || level > 9) fail("ValueError", "compresslevel must be between 1 and 9");
        auto o = std::make_unique<nybz::Obj>();
        o->c.init((int)level);
        std::lock_guard<std::mutex> l(nybz::mu());
        int64_t id = nybz::g_next++;
        nybz::table()[id] = std::move(o);
        return Value(id);
    }
    if (name == "_bz2_dnew") {
        auto o = std::make_unique<nybz::Obj>();
        o->is_c = false;
        std::lock_guard<std::mutex> l(nybz::mu());
        int64_t id = nybz::g_next++;
        nybz::table()[id] = std::move(o);
        return Value(id);
    }
    if (name == "_bz2_free") {
        std::lock_guard<std::mutex> l(nybz::mu());
        nybz::table().erase(int_arg(arg(0)));
        return NONE_VALUE;
    }
    if (name == "_bz2_compress") {
        std::string d = bytes_arg(E, arg(1));
        nybz::Obj* o;
        { std::lock_guard<std::mutex> l(nybz::mu()); o = get(int_arg(arg(0))); }
        if (o->c.finished) fail("ValueError", "Compressor has been flushed");
        o->c.feed((const unsigned char*)d.data(), d.size());
        std::string out;
        out.swap(o->c.out);
        return E.makeBytesValue(out);
    }
    if (name == "_bz2_flush") {
        nybz::Obj* o;
        { std::lock_guard<std::mutex> l(nybz::mu()); o = get(int_arg(arg(0))); }
        if (o->c.finished) fail("ValueError", "Repeated call to flush()");
        o->c.finish();
        std::string out;
        out.swap(o->c.out);
        return E.makeBytesValue(out);
    }
    if (name == "_bz2_decompress") {
        std::string d = bytes_arg(E, arg(1));
        int64_t maxlen = int_arg(arg(2));
        nybz::Obj* o;
        { std::lock_guard<std::mutex> l(nybz::mu()); o = get(int_arg(arg(0))); }
        nybz::Decompressor& z = o->d;
        if (z.eof && z.pending.empty()) fail("EOFError", "End of stream already reached");
        z.in += d;
        try { z.run(); }
        catch (nybz::BzError& e) { z.in.clear(); z.bitpos = 0; fail("OSError", e.msg); }
        std::string out;
        if (maxlen < 0 || (size_t)maxlen >= z.pending.size()) out.swap(z.pending);
        else { out = z.pending.substr(0, (size_t)maxlen); z.pending.erase(0, (size_t)maxlen); }
        // CPython's: eof once the end marker is read and all output handed
        // out; needs_input false while decoded data waits
        bool eof = z.eof && z.pending.empty();
        bool needs = !z.eof && z.pending.empty();
        std::vector<Value> v{E.makeBytesValue(out), Value(eof), E.makeBytesValue(eof ? z.unused : std::string()), Value(needs)};
        return E.makeListValue(v);
    }
    return UNDEFINED_VALUE;
}
#endif // NYBZ_CORE_ONLY
