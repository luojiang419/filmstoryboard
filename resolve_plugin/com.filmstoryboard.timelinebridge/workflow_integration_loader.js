'use strict';

const fs = require('node:fs');
const path = require('node:path');

function workflowIntegrationCandidates(baseDirectory = __dirname) {
  const candidates = [path.join(baseDirectory, 'WorkflowIntegration.node')];
  const programData = process.env.PROGRAMDATA;
  if (programData) {
    const examplesRoot = path.join(
      programData,
      'Blackmagic Design',
      'DaVinci Resolve',
      'Support',
      'Developer',
      'Workflow Integrations',
      'Examples',
    );
    candidates.push(
      path.join(examplesRoot, 'SamplePromisePlugin', 'WorkflowIntegration.node'),
      path.join(examplesRoot, 'SamplePlugin', 'WorkflowIntegration.node'),
    );
  }
  return candidates;
}

function loadWorkflowIntegration(options = {}) {
  const requireModule = options.requireModule || require;
  const candidates = workflowIntegrationCandidates(options.baseDirectory);
  const failures = [];

  for (const candidate of candidates) {
    if (!fs.existsSync(candidate)) {
      continue;
    }
    try {
      return requireModule(candidate);
    } catch (error) {
      failures.push(`${candidate}: ${error.message}`);
    }
  }

  const detail = failures.length > 0 ? `\n${failures.join('\n')}` : '';
  const error = new Error(
    `未找到与当前 Resolve 匹配的 WorkflowIntegration.node。${detail}`,
  );
  error.code = 'WORKFLOW_INTEGRATION_NOT_FOUND';
  throw error;
}

module.exports = {
  loadWorkflowIntegration,
  workflowIntegrationCandidates,
};
