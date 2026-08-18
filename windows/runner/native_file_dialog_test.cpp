#include "native_file_dialog.h"

#include <flutter/encodable_value.h>

#include <iostream>
#include <string>

namespace {

using filmstoryboard::NativeFileDialogMode;
using filmstoryboard::NativeFileDialogRequest;
using filmstoryboard::NativeFileDialogResponse;
using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;

bool Expect(bool condition, const char *message) {
  if (!condition) {
    std::cerr << message << std::endl;
  }
  return condition;
}

bool ParsesOpenFilesArguments() {
  EncodableMap filter;
  filter[EncodableValue("label")] = EncodableValue("Images");
  filter[EncodableValue("extensions")] = EncodableValue(
      EncodableList{EncodableValue("png"), EncodableValue("jpg")});
  EncodableMap arguments;
  arguments[EncodableValue("initialDirectory")] =
      EncodableValue("C:\\workspace");
  arguments[EncodableValue("suggestedName")] = EncodableValue();
  arguments[EncodableValue("confirmButtonText")] = EncodableValue("Import");
  arguments[EncodableValue("filters")] =
      EncodableValue(EncodableList{EncodableValue(filter)});

  NativeFileDialogRequest request;
  std::string error;
  const EncodableValue encoded_arguments(arguments);
  const bool parsed = filmstoryboard::ParseNativeFileDialogRequest(
      &encoded_arguments, NativeFileDialogMode::kOpenFiles, &request, &error);
  return Expect(parsed, error.c_str()) &&
         Expect(request.mode == NativeFileDialogMode::kOpenFiles,
                "openFiles mode was not preserved") &&
         Expect(request.initial_directory == "C:\\workspace",
                "initial directory was not parsed") &&
         Expect(request.confirm_button_text == "Import",
                "confirmation text was not parsed") &&
         Expect(request.filters.size() == 1, "filter count was not parsed") &&
         Expect(request.filters[0].extensions.size() == 2,
                "filter extensions were not parsed");
}

bool RejectsInvalidFilterExtensions() {
  EncodableMap filter;
  filter[EncodableValue("label")] = EncodableValue("Images");
  filter[EncodableValue("extensions")] =
      EncodableValue(EncodableList{EncodableValue(7)});
  EncodableMap arguments;
  arguments[EncodableValue("filters")] =
      EncodableValue(EncodableList{EncodableValue(filter)});

  NativeFileDialogRequest request;
  std::string error;
  const EncodableValue encoded_arguments(arguments);
  const bool parsed = filmstoryboard::ParseNativeFileDialogRequest(
      &encoded_arguments, NativeFileDialogMode::kOpen, &request, &error);
  return Expect(!parsed, "invalid extension unexpectedly parsed") &&
         Expect(error == "Filter extensions must be strings",
                "invalid extension error changed");
}

bool EncodesPathsAndActiveFilter() {
  NativeFileDialogResponse response;
  response.paths = {"C:\\one.png", "C:\\two.jpg"};
  response.active_filter_index = 1;
  const EncodableValue encoded =
      filmstoryboard::EncodeNativeFileDialogResponse(response);
  const auto *map = std::get_if<EncodableMap>(&encoded);
  if (!Expect(map != nullptr, "response was not encoded as a map")) {
    return false;
  }
  const auto paths_iterator = map->find(EncodableValue("paths"));
  const auto filter_iterator = map->find(EncodableValue("activeFilterIndex"));
  return Expect(paths_iterator != map->end(), "encoded paths are missing") &&
         Expect(std::get<EncodableList>(paths_iterator->second).size() == 2,
                "encoded path count changed") &&
         Expect(filter_iterator != map->end(),
                "encoded active filter is missing") &&
         Expect(std::get<int64_t>(filter_iterator->second) == 1,
                "encoded active filter changed");
}

} // namespace

int main() {
  if (!ParsesOpenFilesArguments() || !RejectsInvalidFilterExtensions() ||
      !EncodesPathsAndActiveFilter()) {
    return 1;
  }
  std::cout << "native_file_dialog_test: passed" << std::endl;
  return 0;
}
