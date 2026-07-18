#!/usr/bin/env bash
# Semantic regression test for the blocking CI contract. This intentionally
# parses GitHub Actions YAML with Psych instead of searching raw text.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORKFLOW="$ROOT/.github/workflows/tests.yml"
exec ruby - "$WORKFLOW" <<'RUBY'
require 'yaml'
require 'set'

path = ARGV.fetch(0)
workflow = YAML.load_file(path)
raise 'workflow must be a mapping' unless workflow.is_a?(Hash)
jobs = workflow.fetch('jobs')
raise 'jobs must be a mapping' unless jobs.is_a?(Hash)

events = workflow['on'] || workflow[true]
raise 'workflow must trigger pull requests' unless events.is_a?(Hash) && events.key?('pull_request')
raise 'workflow must trigger scheduled TSan' unless events.key?('schedule')
raise 'workflow must support manual dispatch' unless events.key?('workflow_dispatch')

%w[unit coverage tsan appkit lint security documentation].each do |job|
  raise "missing blocking #{job} job" unless jobs.key?(job)
end

xcode_jobs = %w[unit coverage tsan appkit]
expected_developer_dir = '/Applications/Xcode_26.0.1.app/Contents/Developer'
workflow_env = workflow.fetch('env')
raise 'workflow must select the concrete Xcode 26.0.1 developer directory' unless workflow_env['DEVELOPER_DIR'] == expected_developer_dir
xcode_jobs.each do |job|
  raise "#{job} job must run on macos-26" unless jobs.fetch(job)['runs-on'] == 'macos-26'
  job_env = jobs.fetch(job)['env'] || {}
  raise "#{job} job must inherit the pinned developer directory" if job_env.key?('DEVELOPER_DIR')
end

steps = ->(job) { Array(jobs.fetch(job).fetch('steps')) }
step_runs = ->(job) { steps.call(job).map { |step| step['run'] if step.is_a?(Hash) }.compact }
xcode_jobs.each do |job|
  toolchain_runs = step_runs.call(job).join("\n")
  raise "#{job} job does not fail closed when the pinned Xcode is absent" unless toolchain_runs.include?('test -d "$DEVELOPER_DIR"')
  raise "#{job} job does not verify xcodebuild version" unless toolchain_runs.include?('xcodebuild -version')
  raise "#{job} job does not enforce the pinned Xcode major-minor" unless toolchain_runs.include?('grep -F "Xcode ${MACTALK_XCODE_VERSION}"')
  raise "#{job} job must not mutate the selected Xcode" if toolchain_runs.include?('xcode-select') || toolchain_runs.include?('sudo ')
end

%w[unit coverage tsan].each do |job|
  install_runs = step_runs.call(job).join("\n")
  raise "#{job} job does not capture the XcodeGen bin directory from the installer" unless install_runs.include?('XCODEGEN_BIN_DIR="$(XCODEGEN_INSTALL_DIR="$RUNNER_TOOL_CACHE/xcodegen/2.44.1" bash scripts/install_xcodegen.sh)"')
  raise "#{job} job does not export XcodeGen onto PATH in the install step" unless install_runs.include?('export PATH="$XCODEGEN_BIN_DIR:$PATH"')
  raise "#{job} job does not publish XcodeGen via GITHUB_PATH" unless install_runs.include?('echo "$XCODEGEN_BIN_DIR" >> "$GITHUB_PATH"')
end

unit_runs = step_runs.call('unit').join("\n")
raise 'unit lane is not the blocking deterministic test command' unless unit_runs.include?('scripts/test-lanes.sh unit')
raise 'unit lane does not verify reproducible generation' unless unit_runs.include?('test_reproducible_project_generation.sh')
raise 'unit lane does not generate the pinned project' unless unit_runs.include?('xcodegen generate')
raise 'unit lane does not test coverage summary schema' unless unit_runs.include?('test_coverage_summary.sh')
forbidden_unit = %w[real-model hardware-validation appkit HUDWindow SettingsWindow StatusBarController]
raise 'unit lane includes an opt-in/non-deterministic test' if forbidden_unit.any? { |word| unit_runs.include?(word) }

coverage_runs = step_runs.call('coverage').join("\n")
coverage_implementation = File.read(File.join(File.dirname(path), '../..', 'scripts/coverage.sh'))
coverage_summary_implementation = File.read(File.join(File.dirname(path), '../..', 'scripts/coverage-summary.sh'))
coverage_runs = "#{coverage_runs}\n#{coverage_implementation}\n#{coverage_summary_implementation}"
%w[scripts/coverage.sh xccov --report --json xccov --report --compact].each do |needle|
  raise "coverage job missing #{needle}" unless coverage_runs.include?(needle)
end
raise 'coverage summary must not use the removed xcresulttool --format json option' if coverage_runs.include?('--format json')
raise 'coverage job must use an explicit result bundle' unless coverage_runs.include?('MacTalk.xcresult')
raise 'coverage job must publish an executed/failed/skipped summary' unless coverage_runs.include?('coverage-summary.sh') && coverage_runs.include?('GITHUB_STEP_SUMMARY')
coverage_uploads = steps.call('coverage').select { |step| step.is_a?(Hash) && step['uses'].to_s.start_with?('actions/upload-artifact@') }
raise 'coverage artifacts are not unconditional' unless coverage_uploads.all? { |step| step['if'].to_s.include?('always()') }
raise 'coverage artifacts omit an xcresult/log/report' unless coverage_uploads.any? { |step| step['with'].to_s.include?('xcresult') } && coverage_uploads.any? { |step| step['with'].to_s.include?('coverage') }

tsan_runs = step_runs.call('tsan').join("\n")
tsan_implementation = File.read(File.join(File.dirname(path), '../..', 'scripts/test-lanes.sh'))
tsan_runs = "#{tsan_runs}\n#{tsan_implementation}"
raise 'TSan job is not limited to schedule/manual execution' unless jobs.fetch('tsan')['if'].to_s.include?('schedule') && jobs.fetch('tsan')['if'].to_s.include?('workflow_dispatch')
%w[tsan-smoke.sh test-lanes.sh tsan enableThreadSanitizer YES].each do |needle|
  raise "TSan job missing #{needle}" unless tsan_runs.include?(needle)
end
raise 'TSan job does not verify an instrumented runtime link' unless tsan_runs.include?('verify-tsan-runtime.sh')

%w[lint security documentation].each do |job|
  raise "#{job} job is not blocking" if jobs.fetch(job).key?('continue-on-error')
  raise "#{job} job has no meaningful command" if step_runs.call(job).join.empty?
end
documentation_runs = step_runs.call('documentation').join("\n")
raise 'documentation job does not execute the docs checker fixture test' unless documentation_runs.include?('scripts/tests/test_ci_docs_checks.sh')

# Every third-party action is immutable; no workflow may opt into hidden lanes.
walk = lambda do |value, &block|
  block.call(value)
  case value
  when Hash then value.each_value { |child| walk.call(child, &block) }
  when Array then value.each { |child| walk.call(child, &block) }
  end
end
walk.call(workflow) do |value|
  if value.is_a?(String) && value.start_with?('actions/')
    raise "unpinned action: #{value}" unless value.match?(/@\h*[0-9a-f]{40}\z/)
  end
end

all_text = File.read(path)
raise 'workflow contains forbidden continue-on-error' if all_text.include?('continue-on-error:')
raise 'workflow uses an unreviewed shell escape' if all_text.match?(/\|\|\s*true/)

cache_text = jobs.fetch('unit').to_s
%w[actions/cache@ hashFiles steps.toolchain.outputs.xcode_version Package.resolved].each do |needle|
  raise "dependency cache is not keyed by #{needle}" unless cache_text.include?(needle)
end

%w[docs/testing/TESTING.md docs/testing/TEST_LANES.md docs/testing/TEST_COVERAGE.md].each do |doc|
  raise "missing documented path #{doc}" unless File.file?(File.join(File.dirname(path), '../..', doc))
end
puts 'CI workflow semantic contract passed'
RUBY
