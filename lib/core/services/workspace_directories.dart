import 'dart:io';

abstract interface class WorkspaceDirectories {
  Directory get workspaceRoot;
  Directory get imports;
  Directory get cuts;
  Directory get storyboards;
  Directory get storyboardFolders;
  Directory get generatedImages;
  Directory get exports;
  Directory get database;
  Directory get temp;
  Directory get logs;
  Directory get videos;
  Directory get frames;
  Directory get analyses;
  Directory get reports;
  Directory get scripts;
  Directory get assets;
  Directory get prompts;
  File get databaseFile;
}
