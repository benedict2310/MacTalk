#!/usr/bin/env bash
# Semantic regression test for the blocking CI contract. This intentionally
# parses GitHub Actions YAML with Psych instead of searching raw text.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORKFLOW="$ROOT/.github/workflows/tests.yml"
RELEASE_WORKFLOW="$ROOT/.github/workflows/release.yml"
exec ruby - "$WORKFLOW" "$RELEASE_WORKFLOW" <<'RUBY'
require 'yaml'
require 'set'

path = ARGV.fetch(0)
release_path = ARGV.fetch(1)
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

release_workflow = YAML.load_file(release_path)
release_jobs = release_workflow.fetch('jobs')
release_build = release_jobs.fetch('build')
release_preflight = release_jobs.fetch('preflight')
raise 'release build job must run on macos-26' unless release_build['runs-on'] == 'macos-26'
raise 'release preflight must remain on ubuntu-24.04' unless release_preflight['runs-on'] == 'ubuntu-24.04'
release_global_env = release_workflow['env'] || {}
raise 'release workflow must not globally export the Xcode developer directory' if release_global_env.key?('DEVELOPER_DIR')
release_preflight_env = release_preflight['env'] || {}
raise 'release preflight must not set the Xcode developer directory' if release_preflight_env.key?('DEVELOPER_DIR')
release_env = release_build.fetch('env')
raise 'release build must set MACTALK_XCODE_VERSION to the exact string 26.0.1' unless release_env['MACTALK_XCODE_VERSION'].is_a?(String) && release_env['MACTALK_XCODE_VERSION'] == '26.0.1'
raise 'release build must select the concrete Xcode 26.0.1 developer directory' unless release_env['DEVELOPER_DIR'] == expected_developer_dir
%w[build notarize].each do |job|
  job_env = release_jobs.fetch(job)['env'] || {}
  raise "release #{job} job env must not use the unavailable runner context" if job_env.values.any? { |value| value.to_s.include?('runner.') }
end
release_steps = Array(release_build.fetch('steps'))
release_step_names = release_steps.map { |step| step['name'] if step.is_a?(Hash) }
toolchain_step_index = release_step_names.index('Verify pinned Xcode toolchain')
signing_step_index = release_step_names.index('Import signing certificate')
raise 'release build must verify Xcode before importing signing secrets' unless toolchain_step_index && signing_step_index && toolchain_step_index < signing_step_index
toolchain_step = release_steps.fetch(toolchain_step_index)
signing_step = release_steps.fetch(signing_step_index)
toolchain_run = toolchain_step['run'].to_s
signing_run = signing_step['run'].to_s
signing_env = signing_step['env'] || {}
raise 'release signing step must consume the certificate password secret' unless signing_env['CERTIFICATE_PASSWORD'].to_s.include?('secrets.MACTALK_CERTIFICATE_PASSWORD')
raise 'release signing step must define the runner-temporary keychain path' unless signing_env['MACTALK_KEYCHAIN_PATH'].to_s == '${{ runner.temp }}/mactalk-release.keychain-db'
raise 'release signing step must import the certificate' unless signing_run.include?('security import')
raise 'release Xcode verification step does not fail closed when the pinned Xcode is absent' unless toolchain_run.include?('test -d "$DEVELOPER_DIR"')
raise 'release Xcode verification step does not verify xcodebuild version' unless toolchain_run.include?('xcodebuild -version')
raise 'release Xcode verification step does not enforce the exact pinned Xcode version' unless toolchain_run.include?('test "$(xcodebuild -version | sed -n \'1p\')" = "Xcode ${MACTALK_XCODE_VERSION}"')
release_runs = release_steps.map { |step| step['run'] if step.is_a?(Hash) }.compact.join("\n")
raise 'release build must not mutate the selected Xcode' if release_runs.include?('xcode-select') || release_runs.include?('sudo ')

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
