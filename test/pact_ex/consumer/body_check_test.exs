defmodule PactEx.Consumer.BodyCheckTest do
  use ExUnit.Case, async: true

  alias PactEx.Consumer.BodyCheck

  # A map or list body is JSON for pact_ffi. These tests feed the validator the
  # decoded JSON, which is exactly what pact_ffi parses.
  defp xml(term), do: BodyCheck.validate(:xml, term |> JSON.encode!() |> JSON.decode!())
  defp form(term), do: BodyCheck.validate(:form, term |> JSON.encode!() |> JSON.decode!())

  defp assert_invalid(result, fragment) do
    assert {:error, message} = result
    assert is_binary(message)
    assert message =~ fragment
  end

  describe "validate/2 for XML descriptions that pact_ffi accepts" do
    test "an element with children and text" do
      assert :ok =
               xml(%{
                 "root" => %{
                   "name" => "root",
                   "children" => [%{"name" => "a", "children" => [%{"content" => "b"}]}]
                 }
               })
    end

    test "a root with no children or attributes" do
      assert :ok = xml(%{"root" => %{"name" => "empty"}})
    end

    test "attributes of any value, and attribute matchers with a value" do
      assert :ok =
               xml(%{
                 "root" => %{
                   "name" => "a",
                   "attributes" => %{
                     "plain" => "x",
                     "number" => 1,
                     "flag" => true,
                     "nothing" => nil,
                     "nested" => %{"not" => "a matcher"},
                     "typed" => %{"pact:matcher:type" => "type", "value" => "x"},
                     "null_value" => %{"pact:matcher:type" => "type", "value" => nil}
                   }
                 }
               })
    end

    test "attributes that are not a map are ignored by pact_ffi" do
      assert :ok = xml(%{"root" => %{"name" => "a", "attributes" => [1, 2]}})
      assert :ok = xml(%{"root" => %{"name" => "a", "attributes" => nil}})
    end

    test "matcher elements, with attributes and children in the value" do
      assert :ok =
               xml(%{
                 "root" => %{
                   "name" => "root",
                   "children" => [
                     %{
                       "pact:matcher:type" => "type",
                       "value" => %{
                         "name" => "item",
                         "attributes" => %{"id" => "1"},
                         "children" => [
                           %{
                             "content" => "text",
                             "matcher" => %{"pact:matcher:type" => "regex", "regex" => "t.*"}
                           }
                         ]
                       }
                     }
                   ]
                 }
               })
    end

    test "a matcher element can be the root, and its own children key is ignored" do
      assert :ok =
               xml(%{
                 "root" => %{
                   "pact:matcher:type" => "type",
                   "value" => %{"name" => "r"},
                   "children" => "ignored, only the value's children count"
                 }
               })
    end

    test "text nodes, with or without a matcher, as children" do
      assert :ok =
               xml(%{
                 "root" => %{
                   "name" => "r",
                   "children" => [
                     %{"content" => "plain"},
                     %{"content" => 1},
                     %{"content" => nil},
                     %{"content" => "m", "matcher" => "not a map, ignored"}
                   ]
                 }
               })
    end

    test "examples that are non-negative integers, or not numbers at all" do
      for examples <- [0, 1, 3, 18_446_744_073_709_551_615, "3", nil, true, [1], %{"a" => 1}] do
        assert :ok =
                 xml(%{
                   "root" => %{
                     "name" => "r",
                     "children" => [%{"name" => "c", "examples" => examples}]
                   }
                 }),
               inspect(examples)
      end
    end

    test "any examples value on the root is ignored" do
      assert :ok = xml(%{"root" => %{"name" => "r", "examples" => -1}})
      assert :ok = xml(%{"root" => %{"name" => "r", "examples" => 1.5}})
    end

    test "unknown keys next to root are ignored" do
      assert :ok = xml(%{"root" => %{"name" => "r"}, "other" => 1})
    end
  end

  describe "validate/2 for XML descriptions that would panic or give no document" do
    test "a top-level list or scalar, which pact_ffi turns into an empty body" do
      assert_invalid(xml([1, 2]), "map")
      assert_invalid(xml([%{"root" => %{"name" => "a"}}]), "map")
    end

    test "a map without a root key" do
      assert_invalid(xml(%{"a" => 1}), "root")
      assert_invalid(xml(%{}), "root")
    end

    test "a root that is not a map" do
      for root <- [nil, "x", 1, [%{"name" => "a"}]] do
        assert_invalid(xml(%{"root" => root}), "root")
      end
    end

    test "a root that is a text node" do
      assert_invalid(xml(%{"root" => %{"content" => "x"}}), "text node")
    end

    test "an object that is not an element, a text node or a matcher (the xml.rs:188 panic)" do
      assert_invalid(xml(%{"root" => %{"a" => "b"}}), "$.root")
      assert_invalid(xml(%{"root" => %{}}), "$.root")

      assert_invalid(
        xml(%{"root" => %{"name" => "r", "children" => [%{"tag" => "x"}]}}),
        "$.root.children[0]"
      )
    end

    test "a matcher element without a value" do
      assert_invalid(xml(%{"root" => %{"pact:matcher:type" => "type"}}), "value")
    end

    test "a matcher element whose value is not a map" do
      for value <- [nil, "x", 1, [%{"name" => "a"}]] do
        assert_invalid(
          xml(%{"root" => %{"pact:matcher:type" => "type", "value" => value}}),
          "value"
        )
      end
    end

    test "a matcher element whose value has no name" do
      assert_invalid(
        xml(%{"root" => %{"pact:matcher:type" => "type", "value" => %{"children" => []}}}),
        "name"
      )
    end

    test "children that are not a list, including null, on elements and matcher values" do
      for children <- [nil, "x", 1, %{"name" => "a"}] do
        assert_invalid(
          xml(%{"root" => %{"name" => "r", "children" => children}}),
          "$.root.children"
        )

        assert_invalid(
          xml(%{
            "root" => %{
              "pact:matcher:type" => "type",
              "value" => %{"name" => "r", "children" => children}
            }
          }),
          "children"
        )
      end
    end

    test "a child that is not a map" do
      for child <- [nil, "text", 1, ["x"]] do
        assert_invalid(
          xml(%{"root" => %{"name" => "r", "children" => [%{"name" => "ok"}, child]}}),
          "$.root.children[1]"
        )
      end
    end

    test "a failing child deep in the tree reports its path" do
      deep = %{
        "root" => %{
          "name" => "r",
          "children" => [%{"name" => "a", "children" => [%{"name" => "b", "children" => ["x"]}]}]
        }
      }

      assert_invalid(xml(deep), "$.root.children[0].children[0].children[0]")
    end

    test "an attribute matcher without a value" do
      assert_invalid(
        xml(%{
          "root" => %{
            "name" => "r",
            "attributes" => %{"ok" => "1", "id" => %{"pact:matcher:type" => "type"}}
          }
        }),
        "id"
      )

      assert_invalid(
        xml(%{
          "root" => %{
            "pact:matcher:type" => "type",
            "value" => %{
              "name" => "r",
              "attributes" => %{"id" => %{"pact:matcher:type" => "type"}}
            }
          }
        }),
        "id"
      )
    end

    test "examples that are negative, fractional or too large, on any kind of child" do
      for examples <- [-1, 1.5, 2.0, 1.0e2, 18_446_744_073_709_551_616] do
        for child <- [
              %{"name" => "c", "examples" => examples},
              %{"content" => "t", "examples" => examples},
              %{
                "pact:matcher:type" => "type",
                "value" => %{"name" => "c"},
                "examples" => examples
              }
            ] do
          assert_invalid(
            xml(%{"root" => %{"name" => "r", "children" => [child]}}),
            "examples"
          )
        end
      end
    end
  end

  describe "validate/2 for form-urlencoded descriptions" do
    test "accepts strings, numbers and lists of them" do
      assert :ok = form(%{"a" => "x", "b" => 1, "c" => 2.5, "d" => ["x", 1], "e" => []})
    end

    test "accepts an empty map" do
      assert :ok = form(%{})
    end

    test "accepts matchers that carry a string or number value, alone or in a list" do
      assert :ok =
               form(%{
                 "a" => %{"pact:matcher:type" => "type", "value" => "x"},
                 "b" => %{"pact:matcher:type" => "integer", "value" => 1},
                 "c" => [
                   %{"pact:matcher:type" => "regex", "value" => "a1", "regex" => "\\w\\d"},
                   %{"pact:matcher:type" => "decimal", "value" => 12.3}
                 ],
                 "d" => %{
                   "pact:matcher:type" => "eachValue",
                   "value" => ["string value"],
                   "rules" => [%{"pact:matcher:type" => "type", "value" => "string"}]
                 }
               })
    end

    test "accepts arrayContains, which takes its values from \"variants\"" do
      assert :ok =
               form(%{
                 "a" => %{
                   "pact:matcher:type" => "arrayContains",
                   "variants" => ["x", 1, %{"pact:matcher:type" => "type", "value" => "y"}]
                 },
                 "b" => %{"pact:matcher:type" => "array-contains", "variants" => []}
               })
    end

    test "rejects arrayContains without a list of variants, or with variants pact_ffi drops" do
      assert_invalid(form(%{"a" => %{"pact:matcher:type" => "arrayContains"}}), "$.a")

      assert_invalid(
        form(%{"a" => %{"pact:matcher:type" => "arrayContains", "variants" => "x"}}),
        "$.a"
      )

      assert_invalid(
        form(%{
          "a" => %{"pact:matcher:type" => "arrayContains", "variants" => ["x", %{"k" => 1}]}
        }),
        "$.a[1]"
      )

      # "value" is not read for this matcher
      assert_invalid(
        form(%{"a" => %{"pact:matcher:type" => "arrayContains", "value" => ["x"]}}),
        "$.a"
      )
    end

    test "rejects top-level keys that start with pact:, which pact_ffi drops" do
      assert_invalid(form(%{"pact:generator:type" => "x", "a" => "b"}), "pact:generator:type")
      assert_invalid(form(%{"pact:other" => "x"}), "pact:")
    end

    test "accepts keys that merely contain pact:" do
      assert :ok = form(%{"my-pact:key" => "x", "pact" => "y"})
    end

    test "rejects a top-level list" do
      assert_invalid(form([%{"a" => "b"}]), "map")
    end

    test "rejects a nested map" do
      assert_invalid(form(%{"user" => %{"name" => "Ann"}}), "$.user")
    end

    test "rejects booleans and null, which pact_ffi drops" do
      assert_invalid(form(%{"ok" => "1", "flag" => true}), "$.flag")
      assert_invalid(form(%{"flag" => false}), "$.flag")
      assert_invalid(form(%{"nothing" => nil}), "$.nothing")
    end

    test "rejects list items that are not strings or numbers" do
      assert_invalid(form(%{"l" => ["a", %{"k" => "v"}]}), "$.l[1]")
      assert_invalid(form(%{"l" => [["a"]]}), "$.l[0]")
      assert_invalid(form(%{"l" => [nil]}), "$.l[0]")
      assert_invalid(form(%{"l" => [true]}), "$.l[0]")
    end

    test "rejects a matcher with no value, or a value that is not a string, number or list" do
      assert_invalid(form(%{"m" => %{"pact:matcher:type" => "number"}}), "$.m")
      assert_invalid(form(%{"m" => %{"pact:matcher:type" => "boolean", "value" => true}}), "$.m")

      assert_invalid(
        form(%{"m" => %{"pact:matcher:type" => "type", "value" => %{"k" => "v"}}}),
        "$.m"
      )
    end
  end

  describe "decode/1" do
    test "decodes like JSON.decode!/1 when no key repeats" do
      json = ~s({"a":[1,2.5,"x",null,true,{"b":{}}],"c":{"d":[]}})
      assert {:ok, JSON.decode!(json)} == BodyCheck.decode(json)
      assert {:ok, []} = BodyCheck.decode("[]")
      assert {:ok, "x"} = BodyCheck.decode(~s("x"))
    end

    test "fails on a repeated key and names the path" do
      assert_invalid(BodyCheck.decode(~s({"a":1,"a":2})), ~s|$: the key "a"|)

      assert_invalid(
        BodyCheck.decode(~s({"a":{"b":[1,{"c":1,"c":2}]}})),
        ~s|$.a.b[1]: the key "c"|
      )

      assert_invalid(BodyCheck.decode(~s([{}, {"a":1,"\\u0061":2}])), "$[1]")
    end

    test "fails on what is not JSON, including trailing text" do
      for text <- ["", "{", ~s({"a":1} x), "[1,]", ~s({"a":01}), "1e400", ~s("\\ud800")] do
        assert_invalid(BodyCheck.decode(text), "not valid JSON")
      end
    end

    test "tolerates JSON whitespace around the value" do
      assert {:ok, %{"a" => 1}} = BodyCheck.decode(" \n\t{\"a\": 1} \r\n")
    end

    test "sees what JSON encoders write: atom, integer and struct keys" do
      assert_invalid(BodyCheck.decode(JSON.encode!(%{:a => 1, "a" => 2})), "$")
      assert_invalid(BodyCheck.decode(JSON.encode!(%{1 => 1, "1" => 2})), "$")
      assert_invalid(BodyCheck.decode(JSON.encode!(%{nil => 1, "nil" => 2})), "$")
      assert_invalid(BodyCheck.decode(JSON.encode!(%{"s" => [%{:id => 1, "id" => 2}]})), "$.s[0]")
    end
  end

  describe "check/3" do
    @valid_xml ~s({"root":{"name":"r","children":[{"content":"t"}]}})

    test "checks a description that pact_ffi sniffs as JSON" do
      assert :ok = BodyCheck.check(:xml, @valid_xml, :encoded)
      assert :ok = BodyCheck.check(:xml, @valid_xml, :text)
      assert_invalid(BodyCheck.check(:xml, ~s({"root":{"a":"b"}}), :encoded), "$.root")
      assert_invalid(BodyCheck.check(:xml, ~s({"root":{"a":"b"}}), :text), "$.root")
      assert :ok = BodyCheck.check(:form, ~s({"a":"b","n":[1,2]}), :text)
      assert_invalid(BodyCheck.check(:form, ~s({"a":{"b":1}}), :text), "$.a")
    end

    test "text that is not sniffed as JSON is raw: fine for a string, an error for an encoded map" do
      for raw <- ["<a/>", ~s(<?xml version="1.0"?><a/>), "a=1&b=2", "plain"] do
        assert :ok = BodyCheck.check(:xml, raw, :text)
        assert :ok = BodyCheck.check(:form, raw, :text)
      end

      assert_invalid(BodyCheck.check(:xml, ~s({"-a":{"name":"r"}}), :encoded), "description")
      assert_invalid(BodyCheck.check(:form, ~s({"":"x"}), :encoded), "description")
    end

    test "JSON text that is not an object is an error, as pact_ffi would build an empty body" do
      for text <- ["[1]", "123", ~s("x"), "null", "true"] do
        assert_invalid(BodyCheck.check(:xml, text, :text), "not an object")
        assert_invalid(BodyCheck.check(:form, text, :text), "not an object")
      end
    end

    test "text that looks like JSON to pact_ffi but does not parse is an error" do
      for text <- ["1=a&2=b", "null_flag=1", "true=1", ~s({"a), "123 items"] do
        assert_invalid(BodyCheck.check(:form, text, :text), "not valid JSON")
        assert_invalid(BodyCheck.check(:xml, text, :text), "not valid JSON")
      end
    end

    test "a repeated key in the text is an error" do
      assert_invalid(
        BodyCheck.check(:xml, ~s({"root":{"name":"ok"},"root":{"a":"b"}}), :text),
        ~s|the key "root"|
      )

      assert_invalid(BodyCheck.check(:form, ~s({"a":"1","a":"2"}), :text), ~s|the key "a"|)
    end

    test "nesting beyond serde_json's limit is an error, not a panic" do
      deep = String.duplicate("[", 200) <> String.duplicate("]", 200)

      assert_invalid(
        BodyCheck.check(:form, ~s({"a":#{deep}}), :text),
        "128 levels or more"
      )

      assert_invalid(
        BodyCheck.check(:xml, ~s({"root":{"name":"r"},"x":#{deep}}), :text),
        "128 levels or more"
      )
    end

    test "nesting of exactly 128 levels gets the nesting message, not the syntax one" do
      # The object is level 1, so 127 brackets inside it make 128.
      text = ~s({"a":) <> String.duplicate("[", 127) <> String.duplicate("]", 127) <> "}"

      assert {:error, message} = BodyCheck.check(:form, text, :text)
      assert message =~ "nested 128 levels or more (serde_json's limit)"
      refute message =~ "not valid JSON"
    end

    test "127 levels do not get the nesting message" do
      text = ~s({"a":) <> String.duplicate("[", 126) <> String.duplicate("]", 126) <> "}"

      refute match?({:error, "the JSON is nested" <> _}, BodyCheck.check(:form, text, :text))
    end

    test "a map nested 128 levels deep, encoded by PactEx, gets the nesting message" do
      text = JSON.encode!(Enum.reduce(1..128, "x", fn _, acc -> %{"k" => acc} end))

      assert {:error, message} = BodyCheck.check(:form, text, :encoded)
      assert message =~ "nested 128 levels or more (serde_json's limit)"
      refute message =~ "not valid JSON"
    end

    test "invalid JSON keeps the syntax message" do
      assert {:error, message} = BodyCheck.check(:form, ~s({"a":[1,]}), :text)
      assert message =~ "is not valid JSON"
      refute message =~ "128 levels"
    end

    test "a number that serde_json cannot read as an unsigned integer is rejected in examples" do
      desc = fn examples ->
        ~s({"root":{"name":"r","children":[{"name":"c","examples":#{examples}}]}})
      end

      assert :ok = BodyCheck.check(:xml, desc.("2"), :text)

      for bad <- ["-0", "-1", "2.0", "1e2", "18446744073709551616"] do
        assert_invalid(BodyCheck.check(:xml, desc.(bad), :text), "examples")
      end
    end
  end

  test "validate/2 accepts anything for other kinds" do
    assert :ok = BodyCheck.validate(:other, %{"a" => %{"b" => nil}})
    assert :ok = BodyCheck.validate(:other, [1, 2])
  end
end
