# Copyright 2021 Google LLC
#
# Use of this source code is governed by an MIT-style
# license that can be found in the LICENSE file or at
# https://opensource.org/licenses/MIT.

require_relative "statement_result"
require "google/rpc/error_details_pb"
require "google/spanner/v1/spanner_pb"
require "google/spanner/v1/spanner_services_pb"
require "google/cloud/spanner/v1/spanner"

require "grpc"
require "gapic/grpc/service_stub"
require "securerandom"

# Mock implementation of Spanner
class SpannerMockServer < Google::Cloud::Spanner::V1::Spanner::Service
  attr_reader :requests

  def initialize
    super
    @statement_results = {}
    @sessions = {}
    @transactions = {}
    @aborted_transactions = {}
    @requests = []
    put_statement_result "SELECT 1", StatementResult.create_select1_result
  end

  def put_statement_result sql, result
    @statement_results[sql] = result
  end

  def create_session request, _unused_call
    @requests << request
    do_create_session request.database
  end

  def batch_create_sessions request, _unused_call
    @requests << request
    num_created = 0
    response = Google::Cloud::Spanner::V1::BatchCreateSessionsResponse.new
    while num_created < request.session_count
      response.session << do_create_session(request.database)
      num_created += 1
    end
    response
  end

  def get_session request, _unused_call
    @requests << request
    @sessions[request.name]
  end

  def list_sessions request, _unused_call
    @requests << request
    response = Google::Cloud::Spanner::V1::ListSessionsResponse.new
    @sessions.each_value do |s|
      response.sessions << s
    end
    response
  end

  def delete_session request, _unused_call
    @requests << request
    @sessions.delete request.name
  end

  def execute_sql request, _unused_call
    do_execute_sql request, false
  end

  def execute_streaming_sql request, _unused_call
    do_execute_sql request, true
  end

  # @private
  def do_execute_sql request, streaming
    @requests << request
    validate_session request.session
    validate_transaction request.session, request.transaction.id if request.transaction&.id
    result = get_statement_result request.sql
    if result.result_type == StatementResult::EXCEPTION
      raise result.result
    end
    if streaming
      result.each
    else
      result.result
    end
  end

  def execute_batch_dml request, _unused_call
    @requests << request
    raise GRPC::BadStatus.new GRPC::Core::StatusCodes::UNIMPLEMENTED, "Not yet implemented"
  end

  def read request, _unused_call
    @requests << request
    raise GRPC::BadStatus.new GRPC::Core::StatusCodes::UNIMPLEMENTED, "Not yet implemented"
  end

  def streaming_read request, _unused_call
    @requests << request
    raise GRPC::BadStatus.new GRPC::Core::StatusCodes::UNIMPLEMENTED, "Not yet implemented"
  end

  def begin_transaction request, _unused_call
    @requests << request
    validate_session request.session
    transaction = do_create_transaction request.session
    if @abort_next_transaction
      abort_transaction request.session, transaction.id
      @abort_next_transaction = false
    end
    transaction
  end

  def commit request, _unused_call
    @requests << request
    validate_session request.session
    validate_transaction request.session, request.transaction_id
    Google::Cloud::Spanner::V1::CommitResponse.new commit_timestamp: Google::Protobuf::Timestamp.new(seconds: Time.now.to_i)
  end

  def rollback request, _unused_call
    @requests << request
    validate_session request.session
    name = "#{request.session}/transactions/#{request.transaction_id}"
    @transactions.delete name
    Google::Protobuf::Empty.new
  end

  def partition_query request, _unused_call
    @requests << request
    raise GRPC::BadStatus.new GRPC::Core::StatusCodes::UNIMPLEMENTED, "Not yet implemented"
  end

  def partition_read request, _unused_call
    @requests << request
    raise GRPC::BadStatus.new GRPC::Core::StatusCodes::UNIMPLEMENTED, "Not yet implemented"
  end

  def get_database request, _unused_call
    @requests << request
    raise GRPC::BadStatus.new GRPC::Core::StatusCodes::UNIMPLEMENTED, "Not yet implemented"
  end

  def abort_transaction session, id
    return if session.nil? || id.nil?
    name = "#{session}/transactions/#{id}"
    @aborted_transactions[name] = true
  end

  def abort_next_transaction
    @abort_next_transaction = true
  end

  def get_statement_result sql
    unless @statement_results.has_key? sql
      @statement_results.each do |key,value|
        if key.ends_with?("%") && sql.starts_with?(key.chop)
          return value
        end
      end
      raise GRPC::BadStatus.new(
        GRPC::Core::StatusCodes::INVALID_ARGUMENT,
        "There's no result registered for #{sql}"
      )
    end
    @statement_results[sql]
  end

  private

  def validate_session session
    unless @sessions.has_key? session
      raise GRPC::BadStatus.new(
        GRPC::Core::StatusCodes::NOT_FOUND,
        "Session not found: Session with id #{session} not found"
      )
    end
  end

  def do_create_session database
    name = "#{database}/sessions/#{SecureRandom.uuid}"
    session = Google::Cloud::Spanner::V1::Session.new name: name
    @sessions[name] = session
    session
  end

  def validate_transaction session, transaction
    name = "#{session}/transactions/#{transaction}"
    unless @transactions.has_key? name
      raise GRPC::BadStatus.new(
        GRPC::Core::StatusCodes::NOT_FOUND,
        "Transaction not found: Transaction with id #{transaction} not found"
      )
    end
    if @aborted_transactions.has_key?(name)
      retry_info = Google::Rpc::RetryInfo.new(retry_delay: Google::Protobuf::Duration.new(seconds: 0, nanos: 1))
      raise GRPC::BadStatus.new(
        GRPC::Core::StatusCodes::ABORTED,
        "Transaction aborted",
        { "google.rpc.retryinfo-bin": Google::Rpc::RetryInfo.encode(retry_info) }
      )
    end
  end

  def do_create_transaction session
    id = SecureRandom.uuid
    name = "#{session}/transactions/#{id}"
    transaction = Google::Cloud::Spanner::V1::Transaction.new id: id
    @transactions[name] = transaction
    transaction
  end

end