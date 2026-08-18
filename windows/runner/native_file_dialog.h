#ifndef RUNNER_NATIVE_FILE_DIALOG_H_
#define RUNNER_NATIVE_FILE_DIALOG_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <vector>

namespace filmstoryboard {

enum class NativeFileDialogMode { kOpen, kOpenFiles, kSave };

struct NativeFileDialogFilter {
  std::string label;
  std::vector<std::string> extensions;
};

struct NativeFileDialogRequest {
  NativeFileDialogMode mode = NativeFileDialogMode::kOpen;
  std::optional<std::string> initial_directory;
  std::optional<std::string> suggested_name;
  std::optional<std::string> confirm_button_text;
  std::vector<NativeFileDialogFilter> filters;
};

struct NativeFileDialogResponse {
  bool cancelled = false;
  std::vector<std::string> paths;
  std::optional<int64_t> active_filter_index;
  std::string error_code;
  std::string error_message;
  int32_t error_hresult = 0;

  bool has_error() const { return !error_code.empty(); }
};

// Converts the MethodChannel argument map into the thread-safe request value
// passed to the STA worker. Exposed for the native conversion test target.
bool ParseNativeFileDialogRequest(const flutter::EncodableValue *arguments,
                                  NativeFileDialogMode mode,
                                  NativeFileDialogRequest *request,
                                  std::string *error_message);

// Converts a completed worker response into the StandardMethodCodec payload.
// Exposed for the native conversion test target.
flutter::EncodableValue
EncodeNativeFileDialogResponse(const NativeFileDialogResponse &response);

class NativeFileDialogChannel {
public:
  NativeFileDialogChannel(flutter::BinaryMessenger *messenger,
                          HWND owner_window);
  ~NativeFileDialogChannel();

  NativeFileDialogChannel(const NativeFileDialogChannel &) = delete;
  NativeFileDialogChannel &operator=(const NativeFileDialogChannel &) = delete;

  // Returns true when |message| belongs to this channel. This must be called
  // from the Runner window procedure so Flutter responses complete on the
  // platform thread rather than on the dialog STA thread.
  bool HandleWindowMessage(UINT message);

private:
  struct State;

  std::shared_ptr<State> state_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

} // namespace filmstoryboard

#endif // RUNNER_NATIVE_FILE_DIALOG_H_
