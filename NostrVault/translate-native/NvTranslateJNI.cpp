// JNI bridge for "Translate post": Mozilla's Bergamot engine (the one in
// Firefox Translations) for translation, fastText's lid.176 for language ID.
// Kotlin side: com.nostrvault.service.translate.BergamotNative.
//
// Handles are raw pointers passed as jlong. The Kotlin side calls these from
// one thread at a time (BlockingService is not thread-safe) and frees the
// model handles it creates; the one service lives as long as the process.

#include <jni.h>
#include <android/log.h>

#include <memory>
#include <sstream>
#include <string>
#include <vector>

#include "translator/parser.h"
#include "translator/response.h"
#include "translator/response_options.h"
#include "translator/service.h"
#include "translator/translation_model.h"

#include "fasttext.h"

using marian::bergamot::BlockingService;
using marian::bergamot::Response;
using marian::bergamot::ResponseOptions;
using marian::bergamot::TranslationModel;

namespace {

constexpr const char *kTag = "NvTranslate";

std::string toStd(JNIEnv *env, jstring s) {
  if (s == nullptr) return {};
  const char *chars = env->GetStringUTFChars(s, nullptr);
  std::string out(chars);
  env->ReleaseStringUTFChars(s, chars);
  return out;
}

// NewStringUTF wants modified UTF-8 and aborts on 4-byte sequences (emoji),
// so build the Java string from UTF-16 instead.
jstring toJava(JNIEnv *env, const std::string &utf8) {
  std::u16string utf16;
  utf16.reserve(utf8.size());
  for (size_t i = 0; i < utf8.size();) {
    unsigned char c = static_cast<unsigned char>(utf8[i]);
    uint32_t cp;
    size_t len;
    if (c < 0x80) { cp = c; len = 1; }
    else if ((c >> 5) == 0x6) { cp = c & 0x1F; len = 2; }
    else if ((c >> 4) == 0xE) { cp = c & 0x0F; len = 3; }
    else if ((c >> 3) == 0x1E) { cp = c & 0x07; len = 4; }
    else { utf16.push_back(0xFFFD); i++; continue; }
    if (i + len > utf8.size()) { utf16.push_back(0xFFFD); break; }
    bool ok = true;
    for (size_t k = 1; k < len; k++) {
      unsigned char cc = static_cast<unsigned char>(utf8[i + k]);
      if ((cc >> 6) != 0x2) { ok = false; break; }
      cp = (cp << 6) | (cc & 0x3F);
    }
    if (!ok) { utf16.push_back(0xFFFD); i++; continue; }
    i += len;
    if (cp >= 0x10000) {
      cp -= 0x10000;
      utf16.push_back(static_cast<char16_t>(0xD800 + (cp >> 10)));
      utf16.push_back(static_cast<char16_t>(0xDC00 + (cp & 0x3FF)));
    } else {
      utf16.push_back(static_cast<char16_t>(cp));
    }
  }
  return env->NewString(reinterpret_cast<const jchar *>(utf16.data()), static_cast<jsize>(utf16.size()));
}

std::vector<std::string> toStdArray(JNIEnv *env, jobjectArray arr) {
  std::vector<std::string> out;
  jsize n = env->GetArrayLength(arr);
  out.reserve(n);
  for (jsize i = 0; i < n; i++) {
    auto s = static_cast<jstring>(env->GetObjectArrayElement(arr, i));
    out.push_back(toStd(env, s));
    env->DeleteLocalRef(s);
  }
  return out;
}

jobjectArray toJavaArray(JNIEnv *env, const std::vector<Response> &responses) {
  jclass stringClass = env->FindClass("java/lang/String");
  jobjectArray out = env->NewObjectArray(static_cast<jsize>(responses.size()), stringClass, nullptr);
  for (size_t i = 0; i < responses.size(); i++) {
    jstring s = toJava(env, responses[i].target.text);
    env->SetObjectArrayElement(out, static_cast<jsize>(i), s);
    env->DeleteLocalRef(s);
  }
  return out;
}

void throwJava(JNIEnv *env, const char *what) {
  __android_log_print(ANDROID_LOG_WARN, kTag, "%s", what);
  jclass ex = env->FindClass("java/lang/IllegalStateException");
  if (ex != nullptr) env->ThrowNew(ex, what);
}

using ModelHandle = std::shared_ptr<TranslationModel>;

}  // namespace

extern "C" {

JNIEXPORT jlong JNICALL
Java_com_nostrvault_service_translate_BergamotNative_createService(JNIEnv *env, jclass) {
  try {
    BlockingService::Config config;
    config.cacheSize = 0;
    config.logger.level = "off";
    return reinterpret_cast<jlong>(new BlockingService(config));
  } catch (const std::exception &e) {
    throwJava(env, e.what());
    return 0;
  }
}

/** [config] is Bergamot's YAML with absolute model, vocab and shortlist paths. */
JNIEXPORT jlong JNICALL
Java_com_nostrvault_service_translate_BergamotNative_loadModel(JNIEnv *env, jclass, jstring config) {
  try {
    auto options = marian::bergamot::parseOptionsFromString(toStd(env, config), /*validate=*/false);
    return reinterpret_cast<jlong>(new ModelHandle(std::make_shared<TranslationModel>(options)));
  } catch (const std::exception &e) {
    throwJava(env, e.what());
    return 0;
  }
}

JNIEXPORT void JNICALL
Java_com_nostrvault_service_translate_BergamotNative_freeModel(JNIEnv *, jclass, jlong model) {
  delete reinterpret_cast<ModelHandle *>(model);
}

JNIEXPORT jobjectArray JNICALL
Java_com_nostrvault_service_translate_BergamotNative_translate(JNIEnv *env, jclass, jlong service, jlong model,
                                                              jobjectArray texts) {
  try {
    auto inputs = toStdArray(env, texts);
    std::vector<ResponseOptions> options(inputs.size());
    auto responses = reinterpret_cast<BlockingService *>(service)->translateMultiple(
        *reinterpret_cast<ModelHandle *>(model), std::move(inputs), options);
    return toJavaArray(env, responses);
  } catch (const std::exception &e) {
    throwJava(env, e.what());
    return nullptr;
  }
}

/** [first] translates into English, [second] out of it: two models for a pair Mozilla has no direct model for. */
JNIEXPORT jobjectArray JNICALL
Java_com_nostrvault_service_translate_BergamotNative_pivot(JNIEnv *env, jclass, jlong service, jlong first,
                                                          jlong second, jobjectArray texts) {
  try {
    auto inputs = toStdArray(env, texts);
    std::vector<ResponseOptions> options(inputs.size());
    auto responses = reinterpret_cast<BlockingService *>(service)->pivotMultiple(
        *reinterpret_cast<ModelHandle *>(first), *reinterpret_cast<ModelHandle *>(second), std::move(inputs),
        options);
    return toJavaArray(env, responses);
  } catch (const std::exception &e) {
    throwJava(env, e.what());
    return nullptr;
  }
}

JNIEXPORT jlong JNICALL
Java_com_nostrvault_service_translate_BergamotNative_loadLanguageId(JNIEnv *env, jclass, jstring path) {
  try {
    auto *model = new fasttext::FastText();
    model->loadModel(toStd(env, path));
    return reinterpret_cast<jlong>(model);
  } catch (const std::exception &e) {
    throwJava(env, e.what());
    return 0;
  }
}

JNIEXPORT void JNICALL
Java_com_nostrvault_service_translate_BergamotNative_freeLanguageId(JNIEnv *, jclass, jlong model) {
  delete reinterpret_cast<fasttext::FastText *>(model);
}

/**
 * The most likely language of [text] as "code probability" ("de 0.97"), or ""
 * when fastText has no guess. Labels come as "__label__de".
 */
JNIEXPORT jstring JNICALL
Java_com_nostrvault_service_translate_BergamotNative_identify(JNIEnv *env, jclass, jlong model, jstring text) {
  try {
    std::string line = toStd(env, text);
    // fastText reads one line; newlines would end the input early.
    for (char &c : line) if (c == '\n' || c == '\r') c = ' ';
    line.push_back('\n');
    std::istringstream in(line);
    std::vector<std::pair<fasttext::real, std::string>> predictions;
    reinterpret_cast<fasttext::FastText *>(model)->predictLine(in, predictions, 1, 0.0);
    if (predictions.empty()) return toJava(env, "");
    std::string label = predictions[0].second;
    const std::string prefix = "__label__";
    if (label.rfind(prefix, 0) == 0) label = label.substr(prefix.size());
    return toJava(env, label + " " + std::to_string(predictions[0].first));
  } catch (const std::exception &e) {
    throwJava(env, e.what());
    return nullptr;
  }
}

}  // extern "C"
