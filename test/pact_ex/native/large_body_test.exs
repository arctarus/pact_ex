defmodule PactEx.Native.LargeBodyTest do
  use ExUnit.Case, async: false

  alias PactEx.{Consumer, HTTP, Native}
  alias PactEx.Consumer.{Apply, BodyCheck}

  @moduletag :tmp_dir
  @moduletag timeout: 120_000

  # About 5 MB of JSON text, and the same description as a map. A scan of a
  # body this size takes tens of milliseconds, far more than the 1 ms a NIF
  # may hold a normal scheduler.
  @children 100_000

  defp description_text do
    child = ~s({"name":"a","children":[{"content":"b"}]})

    ~s({"root":{"name":"r","children":[) <>
      Enum.join(List.duplicate(child, @children), ",") <> "]}}"
  end

  defp description_map do
    child = %{"name" => "a", "children" => [%{"content" => "b"}]}
    %{"root" => %{"name" => "r", "children" => List.duplicate(child, @children)}}
  end

  # The time that the scheduler threads of `type` have spent out of sleep.
  defp busy(type) do
    :microstate_accounting
    |> :erlang.statistics()
    |> Enum.filter(&(&1.type == type))
    |> Enum.map(fn %{counters: counters} ->
      counters |> Map.values() |> Enum.sum() |> Kernel.-(counters.sleep)
    end)
    |> Enum.sum()
  end

  # Runs `fun` with microstate accounting on and returns the busy time it
  # added to the dirty CPU schedulers.
  defp dirty_cpu_busy_during(fun) do
    :erlang.system_flag(:microstate_accounting, true)
    before = busy(:dirty_cpu_scheduler)
    result = fun.()
    {result, busy(:dirty_cpu_scheduler) - before}
  end

  # The scans run on a dirty scheduler thread without a large stack. serde_json
  # recurses once per nesting level and stops at depth 128, so the deepest
  # input it accepts must not overflow that stack.
  test "nesting at serde_json's limit parses on the scheduler thread's own stack" do
    nested = fn depth ->
      ~s({"a":) <>
        String.duplicate("[", depth - 1) <> String.duplicate("]", depth - 1) <> "}"
    end

    assert {:object, rendered} = Native.json_text_shape(nested.(127))
    assert byte_size(rendered) == byte_size(nested.(127))
    assert Native.json_text_shape(nested.(128)) == :too_deep
    assert Native.detect_json(nested.(10_000))
    assert Native.json_text_shape(nested.(10_000)) == :too_deep
  end

  test "the fixtures are multi-megabyte" do
    assert byte_size(description_text()) > 4_000_000
    assert byte_size(JSON.encode!(description_map())) > 4_000_000
  end

  describe "the whole-body scans run on a dirty CPU scheduler" do
    test "detect_json/1" do
      text = description_text()
      assert {true, dirty} = dirty_cpu_busy_during(fn -> Native.detect_json(text) end)
      assert dirty > 0
    end

    test "json_text_shape/1" do
      text = description_text()

      assert {{:object, rendered}, dirty} =
               dirty_cpu_busy_during(fn -> Native.json_text_shape(text) end)

      assert dirty > 0
      assert JSON.decode!(rendered) == description_map()
    end
  end

  describe "BodyCheck.check/3 on a multi-megabyte JSON text" do
    test "a valid XML description is accepted" do
      assert BodyCheck.check(:xml, description_text(), :text) == :ok
    end

    test "text that is not an object is rejected under an XML type" do
      text = "[" <> String.duplicate("1,", 2_000_000) <> "1]"
      assert {:error, message} = BodyCheck.check(:xml, text, :text)
      assert message =~ "not an object"
    end

    test "a form body with a nested value is rejected" do
      big = String.duplicate("x", 5_000_000)
      text = ~s({"a":"#{big}","b":{"c":"d"}})
      assert {:error, message} = BodyCheck.check(:form, text, :text)
      assert message =~ "$.b"
    end

    test "a big form body of strings is accepted" do
      big = String.duplicate("x", 5_000_000)
      assert BodyCheck.check(:form, ~s({"a":"#{big}"}), :text) == :ok
    end

    test "text that looks like JSON but does not parse is rejected" do
      text = ~s({"a":"#{String.duplicate("x", 5_000_000)}") <> ",}"
      assert {:error, message} = BodyCheck.check(:xml, text, :text)
      assert message =~ "not valid JSON"
    end

    test "a big raw string that is not sniffed as JSON is sent as it is" do
      text = String.duplicate("a=1&", 1_250_000)
      assert BodyCheck.check(:form, text, :text) == :ok
    end
  end

  describe "a multi-megabyte map body through the interaction" do
    defp response_with(body, opts) do
      HTTP.interaction("large")
      |> HTTP.with_request(:get, "/large")
      |> HTTP.will_respond_with(200, [body: body] ++ opts)
    end

    test "a map body under an XML type is validated as a description" do
      xml = %{"Content-Type" => "application/xml"}
      assert Apply.validate(response_with(description_map(), headers: xml)) == :ok

      invalid = %{"a" => String.duplicate("x", 5_000_000)}

      assert {:error, %PactEx.Error{code: -101, message: message}} =
               Apply.validate(response_with(invalid, headers: xml))

      assert message =~ ~s(no "root" key)
    end

    test "a map body under a form type is validated as a description" do
      form = %{"Content-Type" => "application/x-www-form-urlencoded"}
      big = %{"a" => String.duplicate("x", 5_000_000)}
      assert Apply.validate(response_with(big, headers: form)) == :ok

      nested = %{"a" => String.duplicate("x", 5_000_000), "b" => %{"c" => "d"}}

      assert {:error, %PactEx.Error{code: -101, message: message}} =
               Apply.validate(response_with(nested, headers: form))

      assert message =~ "$.b"
    end

    test "a JSON map body is served and written to the pact", %{tmp_dir: dir} do
      body = %{"items" => List.duplicate(%{"name" => "a", "tags" => ["b", "c"]}, 150_000)}
      assert byte_size(JSON.encode!(body)) > 4_000_000
      pact = PactEx.new("large-consumer", "large-provider", pact_dir: dir)

      assert :ok =
               Consumer.run(pact, [response_with(body, [])], fn mock ->
                 response = Req.get!(mock.url <> "/large", decode_body: false)
                 assert response.status == 200
                 assert JSON.decode!(response.body) == body
               end)

      written = dir |> Path.join("large-consumer-large-provider.json") |> File.read!()

      assert [%{"response" => %{"body" => %{"content" => ^body}}}] =
               JSON.decode!(written)["interactions"]
    end
  end
end
