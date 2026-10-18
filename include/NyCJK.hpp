#pragma once
// NyCJK.hpp - the CJK multibyte codecs of both engines (round 84):
// CPython's Modules/cjkcodecs ported to C++ (src/builtins/nycjk.cpp), over
// mapping tables generated from python3's codecs (tools/gen_cjk_codecs.py).
//
//   big5 big5hkscs cp950 gb2312 gbk gb18030 hz euc_jp euc_jis_2004
//   euc_jisx0213 shift_jis shift_jis_2004 shift_jisx0213 cp932 euc_kr cp949
//   johab iso2022_jp iso2022_jp_1 iso2022_jp_2 iso2022_jp_2004 iso2022_jp_3
//   iso2022_jp_ext iso2022_kr
//
// lib/_multibytecodec.ny and lib/_codecs_{cn,hk,iso2022,jp,kr,tw}.ny reach
// them through the _ny_mbc native; str.encode / bytes.decode call
// encode_all / decode_all directly (include/NyCodecs.hpp) when the error
// handler is a builtin one.
#include <string>

namespace nycjk {

// The codec an encoding name stands for (CPython's encodings.aliases
// included: "sjis", "ms932", "csiso2022jp", "936" ...): its C name
// ("shift_jis"), or "" when it is not a CJK codec.
std::string codec_of(const std::string& encoding);

// The whole input with a builtin error handler (strict, ignore, replace,
// backslashreplace, xmlcharrefreplace, namereplace, surrogateescape,
// surrogatepass); errors raise nypy::PyError as the native codecs do
// (UnicodeEncodeError / UnicodeDecodeError with CPython's messages).
std::string encode_all(const std::string& codec, const std::string& s, const std::string& errors);
std::string decode_all(const std::string& codec, const std::string& b, const std::string& errors);

}  // namespace nycjk
