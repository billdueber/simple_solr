require 'minitest_helper'

describe "Basic connection to a running solr" do

  before do
    @core = TempCore.instance.core
    @client = @core.client
  end


  it "gets some sort of response" do
    @client._get('admin/cores').keys.must_include 'status'
  end

  it "gets an OK response from cores" do
    @client._get('admin/cores')['status'].keys.must_include @core.name
  end

  it "gets a ping" do
    @core.get('admin/ping')['status'].must_equal 'OK'
  end



end
