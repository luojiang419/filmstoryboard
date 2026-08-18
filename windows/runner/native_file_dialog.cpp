#include "native_file_dialog.h"

#include <shobjidl.h>
#include <wrl/client.h>

#include <deque>
#include <mutex>
#include <thread>
#include <utility>

#include "flutter/standard_method_codec.h"

namespace filmstoryboard {
namespace {

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;
using MethodResult = flutter::MethodResult<EncodableValue>;
using Microsoft::WRL::ComPtr;

constexpr char kChannelName[] = "filmstoryboard/native_file_dialog";
constexpr UINT kDialogCompletedMessage = WM_APP + 0x421;

const EncodableValue *FindMapValue(const EncodableMap &map, const char *key) {
  const auto iterator = map.find(EncodableValue(key));
  return iterator == map.end() ? nullptr : &iterator->second;
}

bool ReadOptionalString(const EncodableMap &map, const char *key,
                        std::optional<std::string> *output,
                        std::string *error_message) {
  const EncodableValue *value = FindMapValue(map, key);
  if (value == nullptr || value->IsNull()) {
    output->reset();
    return true;
  }
  const auto *string_value = std::get_if<std::string>(value);
  if (string_value == nullptr) {
    *error_message = std::string("Argument '") + key + "' must be a string";
    return false;
  }
  *output = *string_value;
  return true;
}

std::wstring Utf16FromUtf8(const std::string &value) {
  if (value.empty()) {
    return std::wstring();
  }
  const int length =
      MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                          static_cast<int>(value.size()), nullptr, 0);
  if (length <= 0) {
    return std::wstring();
  }
  std::wstring converted(static_cast<size_t>(length), L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                      static_cast<int>(value.size()), converted.data(), length);
  return converted;
}

std::string Utf8FromUtf16(const wchar_t *value) {
  if (value == nullptr || *value == L'\0') {
    return std::string();
  }
  const int source_length = static_cast<int>(wcslen(value));
  const int length =
      WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value, source_length,
                          nullptr, 0, nullptr, nullptr);
  if (length <= 0) {
    return std::string();
  }
  std::string converted(static_cast<size_t>(length), '\0');
  WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value, source_length,
                      converted.data(), length, nullptr, nullptr);
  return converted;
}

std::string GetPath(IShellItem *item) {
  if (item == nullptr) {
    return std::string();
  }
  wchar_t *path = nullptr;
  const HRESULT result = item->GetDisplayName(SIGDN_FILESYSPATH, &path);
  if (FAILED(result)) {
    return std::string();
  }
  std::string converted = Utf8FromUtf16(path);
  CoTaskMemFree(path);
  return converted;
}

void SetInitialDirectory(IFileDialog *dialog,
                         const std::optional<std::string> &directory) {
  if (!directory.has_value()) {
    return;
  }
  const std::wstring wide_directory = Utf16FromUtf8(*directory);
  if (wide_directory.empty()) {
    return;
  }
  ComPtr<IShellItem> folder;
  if (SUCCEEDED(SHCreateItemFromParsingName(wide_directory.c_str(), nullptr,
                                            IID_PPV_ARGS(&folder)))) {
    dialog->SetFolder(folder.Get());
  }
}

void SetFilters(IFileDialog *dialog,
                const std::vector<NativeFileDialogFilter> &filters) {
  if (filters.empty()) {
    return;
  }
  std::vector<std::wstring> names;
  std::vector<std::wstring> patterns;
  names.reserve(filters.size());
  patterns.reserve(filters.size());
  for (const NativeFileDialogFilter &filter : filters) {
    names.push_back(Utf16FromUtf8(filter.label));
    std::wstring pattern;
    if (filter.extensions.empty()) {
      pattern = L"*.*";
    } else {
      for (const std::string &extension : filter.extensions) {
        if (!pattern.empty()) {
          pattern += L";";
        }
        pattern += L"*.";
        pattern += Utf16FromUtf8(extension);
      }
    }
    patterns.push_back(std::move(pattern));
  }

  std::vector<COMDLG_FILTERSPEC> specs;
  specs.reserve(filters.size());
  for (size_t index = 0; index < filters.size(); ++index) {
    specs.push_back({names[index].c_str(), patterns[index].c_str()});
  }
  dialog->SetFileTypes(static_cast<UINT>(specs.size()), specs.data());
}

NativeFileDialogResponse
ShowDialogOnStaThread(const NativeFileDialogRequest &request,
                      HWND owner_window) {
  NativeFileDialogResponse response;
  const HRESULT initialize_result =
      CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  if (FAILED(initialize_result)) {
    response.error_code = "com-initialization-failed";
    response.error_message = "Could not initialize the file dialog STA";
    response.error_hresult = static_cast<int32_t>(initialize_result);
    return response;
  }

  const bool is_save = request.mode == NativeFileDialogMode::kSave;
  ComPtr<IFileDialog> dialog;
  const HRESULT create_result =
      CoCreateInstance(is_save ? CLSID_FileSaveDialog : CLSID_FileOpenDialog,
                       nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&dialog));
  if (FAILED(create_result)) {
    response.error_code = "dialog-creation-failed";
    response.error_message = "Could not create the native file dialog";
    response.error_hresult = static_cast<int32_t>(create_result);
    CoUninitialize();
    return response;
  }

  FILEOPENDIALOGOPTIONS options = 0;
  if (SUCCEEDED(dialog->GetOptions(&options))) {
    if (request.mode == NativeFileDialogMode::kOpenFiles) {
      options |= FOS_ALLOWMULTISELECT;
    }
    dialog->SetOptions(options);
  }
  SetInitialDirectory(dialog.Get(), request.initial_directory);
  SetFilters(dialog.Get(), request.filters);
  if (request.suggested_name.has_value()) {
    const std::wstring suggested_name = Utf16FromUtf8(*request.suggested_name);
    dialog->SetFileName(suggested_name.c_str());
  }
  if (request.confirm_button_text.has_value()) {
    const std::wstring confirm_text =
        Utf16FromUtf8(*request.confirm_button_text);
    dialog->SetOkButtonLabel(confirm_text.c_str());
  }

  const HRESULT show_result = dialog->Show(owner_window);
  if (show_result == HRESULT_FROM_WIN32(ERROR_CANCELLED)) {
    response.cancelled = true;
    CoUninitialize();
    return response;
  }
  if (FAILED(show_result)) {
    response.error_code = "dialog-show-failed";
    response.error_message = "Could not show the native file dialog";
    response.error_hresult = static_cast<int32_t>(show_result);
    CoUninitialize();
    return response;
  }

  if (is_save) {
    ComPtr<IShellItem> item;
    const HRESULT result = dialog->GetResult(&item);
    if (SUCCEEDED(result)) {
      response.paths.push_back(GetPath(item.Get()));
    } else {
      response.error_code = "dialog-result-failed";
      response.error_message = "Could not read the selected save path";
      response.error_hresult = static_cast<int32_t>(result);
    }
  } else {
    ComPtr<IFileOpenDialog> open_dialog;
    HRESULT result = dialog.As(&open_dialog);
    ComPtr<IShellItemArray> items;
    if (SUCCEEDED(result)) {
      result = open_dialog->GetResults(&items);
    }
    DWORD count = 0;
    if (SUCCEEDED(result)) {
      result = items->GetCount(&count);
    }
    if (SUCCEEDED(result)) {
      for (DWORD index = 0; index < count; ++index) {
        ComPtr<IShellItem> item;
        if (SUCCEEDED(items->GetItemAt(index, &item))) {
          response.paths.push_back(GetPath(item.Get()));
        }
      }
    } else {
      response.error_code = "dialog-result-failed";
      response.error_message = "Could not read the selected file paths";
      response.error_hresult = static_cast<int32_t>(result);
    }
  }

  UINT filter_index = 0;
  if (SUCCEEDED(dialog->GetFileTypeIndex(&filter_index)) && filter_index > 0) {
    response.active_filter_index = static_cast<int64_t>(filter_index - 1);
  }
  CoUninitialize();
  return response;
}

} // namespace

struct NativeFileDialogChannel::State {
  struct Completion {
    std::shared_ptr<MethodResult> result;
    NativeFileDialogResponse response;
  };

  std::mutex mutex;
  HWND owner_window = nullptr;
  bool active = true;
  std::deque<Completion> completions;
};

bool ParseNativeFileDialogRequest(const EncodableValue *arguments,
                                  NativeFileDialogMode mode,
                                  NativeFileDialogRequest *request,
                                  std::string *error_message) {
  if (request == nullptr || error_message == nullptr) {
    return false;
  }
  const auto *map =
      arguments == nullptr ? nullptr : std::get_if<EncodableMap>(arguments);
  if (map == nullptr) {
    *error_message = "Arguments must be a map";
    return false;
  }

  NativeFileDialogRequest parsed;
  parsed.mode = mode;
  if (!ReadOptionalString(*map, "initialDirectory", &parsed.initial_directory,
                          error_message) ||
      !ReadOptionalString(*map, "suggestedName", &parsed.suggested_name,
                          error_message) ||
      !ReadOptionalString(*map, "confirmButtonText",
                          &parsed.confirm_button_text, error_message)) {
    return false;
  }

  const EncodableValue *filters_value = FindMapValue(*map, "filters");
  if (filters_value != nullptr && !filters_value->IsNull()) {
    const auto *filters = std::get_if<EncodableList>(filters_value);
    if (filters == nullptr) {
      *error_message = "Argument 'filters' must be a list";
      return false;
    }
    parsed.filters.reserve(filters->size());
    for (const EncodableValue &filter_value : *filters) {
      const auto *filter_map = std::get_if<EncodableMap>(&filter_value);
      if (filter_map == nullptr) {
        *error_message = "Each filter must be a map";
        return false;
      }
      const EncodableValue *label_value = FindMapValue(*filter_map, "label");
      const EncodableValue *extensions_value =
          FindMapValue(*filter_map, "extensions");
      const auto *label = label_value == nullptr
                              ? nullptr
                              : std::get_if<std::string>(label_value);
      const auto *extensions =
          extensions_value == nullptr
              ? nullptr
              : std::get_if<EncodableList>(extensions_value);
      if (label == nullptr || extensions == nullptr) {
        *error_message =
            "Each filter requires a string label and extension list";
        return false;
      }
      NativeFileDialogFilter filter;
      filter.label = *label;
      filter.extensions.reserve(extensions->size());
      for (const EncodableValue &extension_value : *extensions) {
        const auto *extension = std::get_if<std::string>(&extension_value);
        if (extension == nullptr) {
          *error_message = "Filter extensions must be strings";
          return false;
        }
        filter.extensions.push_back(*extension);
      }
      parsed.filters.push_back(std::move(filter));
    }
  }

  *request = std::move(parsed);
  return true;
}

EncodableValue
EncodeNativeFileDialogResponse(const NativeFileDialogResponse &response) {
  EncodableList paths;
  paths.reserve(response.paths.size());
  for (const std::string &path : response.paths) {
    paths.push_back(EncodableValue(path));
  }
  EncodableMap encoded;
  encoded[EncodableValue("cancelled")] = EncodableValue(response.cancelled);
  encoded[EncodableValue("paths")] = EncodableValue(paths);
  encoded[EncodableValue("activeFilterIndex")] =
      response.active_filter_index.has_value()
          ? EncodableValue(*response.active_filter_index)
          : EncodableValue();
  return EncodableValue(encoded);
}

NativeFileDialogChannel::NativeFileDialogChannel(
    flutter::BinaryMessenger *messenger, HWND owner_window)
    : state_(std::make_shared<State>()),
      channel_(
          std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
              messenger, kChannelName,
              &flutter::StandardMethodCodec::GetInstance())) {
  state_->owner_window = owner_window;
  const std::weak_ptr<State> weak_state = state_;
  channel_->SetMethodCallHandler(
      [weak_state](const flutter::MethodCall<EncodableValue> &call,
                   std::unique_ptr<MethodResult> result) {
        NativeFileDialogMode mode;
        if (call.method_name() == "open") {
          mode = NativeFileDialogMode::kOpen;
        } else if (call.method_name() == "openFiles") {
          mode = NativeFileDialogMode::kOpenFiles;
        } else if (call.method_name() == "save") {
          mode = NativeFileDialogMode::kSave;
        } else {
          result->NotImplemented();
          return;
        }

        NativeFileDialogRequest request;
        std::string error_message;
        if (!ParseNativeFileDialogRequest(call.arguments(), mode, &request,
                                          &error_message)) {
          result->Error("invalid-arguments", error_message);
          return;
        }

        const std::shared_ptr<MethodResult> shared_result(result.release());
        std::thread([weak_state, request = std::move(request),
                     shared_result]() {
          const std::shared_ptr<State> state = weak_state.lock();
          if (!state) {
            return;
          }
          HWND owner_window = nullptr;
          {
            std::lock_guard<std::mutex> lock(state->mutex);
            if (!state->active) {
              return;
            }
            owner_window = state->owner_window;
          }

          NativeFileDialogResponse response =
              ShowDialogOnStaThread(request, owner_window);
          HWND completion_window = nullptr;
          {
            std::lock_guard<std::mutex> lock(state->mutex);
            if (!state->active) {
              return;
            }
            completion_window = state->owner_window;
            state->completions.push_back(
                State::Completion{shared_result, std::move(response)});
          }
          if (completion_window != nullptr) {
            PostMessage(completion_window, kDialogCompletedMessage, 0, 0);
          }
        }).detach();
      });
}

NativeFileDialogChannel::~NativeFileDialogChannel() {
  channel_->SetMethodCallHandler(nullptr);
  std::deque<State::Completion> abandoned;
  {
    std::lock_guard<std::mutex> lock(state_->mutex);
    state_->active = false;
    state_->owner_window = nullptr;
    abandoned.swap(state_->completions);
  }
}

bool NativeFileDialogChannel::HandleWindowMessage(UINT message) {
  if (message != kDialogCompletedMessage) {
    return false;
  }
  std::deque<State::Completion> completions;
  {
    std::lock_guard<std::mutex> lock(state_->mutex);
    completions.swap(state_->completions);
  }
  for (State::Completion &completion : completions) {
    if (completion.response.has_error()) {
      completion.result->Error(
          completion.response.error_code, completion.response.error_message,
          EncodableValue(completion.response.error_hresult));
    } else {
      completion.result->Success(
          EncodeNativeFileDialogResponse(completion.response));
    }
  }
  return true;
}

} // namespace filmstoryboard
