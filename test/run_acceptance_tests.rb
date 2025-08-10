#!/usr/bin/env ruby

# Script to run acceptance tests for all implemented user stories
# Run with: ruby test/run_acceptance_tests.rb

puts "🧪 Running Pay Stub Collection Agent - Acceptance Tests"
puts "=" * 60

test_files = [
  "test/integration/loan_approval_trigger_acceptance_test.rb",
  "test/integration/rpa_upload_acceptance_test.rb", 
  "test/integration/rpa_escalation_acceptance_test.rb"
]

test_descriptions = [
  "Story 1: Loan Approval Trigger with Pay Stub Collection",
  "Story 2: RPA Upload with Logging and Retry",
  "Story 3: Human Notification with Full Error Context"
]

results = []

test_files.each_with_index do |test_file, index|
  puts "\n📋 #{test_descriptions[index]}"
  puts "-" * 50
  puts "Running: #{test_file}"
  
  start_time = Time.now
  result = system("rails test #{test_file}")
  end_time = Time.now
  duration = (end_time - start_time).round(2)
  
  if result
    puts "✅ PASSED (#{duration}s)"
    results << { story: test_descriptions[index], status: "PASSED", duration: duration }
  else
    puts "❌ FAILED (#{duration}s)"
    results << { story: test_descriptions[index], status: "FAILED", duration: duration }
  end
end

puts "\n" + "=" * 60
puts "📊 ACCEPTANCE TEST SUMMARY"
puts "=" * 60

total_duration = results.sum { |r| r[:duration] }
passed_count = results.count { |r| r[:status] == "PASSED" }
failed_count = results.count { |r| r[:status] == "FAILED" }

results.each do |result|
  status_icon = result[:status] == "PASSED" ? "✅" : "❌"
  puts "#{status_icon} #{result[:story]} (#{result[:duration]}s)"
end

puts "\n📈 Results:"
puts "   Total Tests: #{results.size}"
puts "   Passed: #{passed_count}"
puts "   Failed: #{failed_count}" 
puts "   Duration: #{total_duration}s"

if failed_count == 0
  puts "\n🎉 All acceptance tests passed! The user stories are fully implemented."
  exit 0
else
  puts "\n⚠️  Some acceptance tests failed. Please review the implementation."
  exit 1
end
