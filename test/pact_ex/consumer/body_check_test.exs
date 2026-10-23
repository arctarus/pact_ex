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

  describe "kind/2" do
    test "recognizes XML types the way pact_ffi does" do
      for ct <- [
            "application/xml",
            "text/xml",
            "application/atom+xml",
            "application/soap+xml; charset=utf-8",
            "Application/XML",
            "TEXT/XML; charset=UTF-8",
            "application/xml;"
          ] do
        assert BodyCheck.kind(ct, nil) == :xml, ct
      end
    end

    test "other types are not XML" do
      for ct <- [
            "application/json",
            "application/hal+json",
            "text/plain",
            "image/svg+xml",
            "application/xmlish",
            "application/octet-stream",
            nil
          ] do
        assert BodyCheck.kind(ct, nil) == :other, inspect(ct)
      end
    end

    test "recognizes form-urlencoded, ignoring case and parameters" do
      assert BodyCheck.kind("application/x-www-form-urlencoded", nil) == :form
      assert BodyCheck.kind("Application/X-WWW-Form-Urlencoded; charset=utf-8", nil) == :form
      assert BodyCheck.kind("text/x-www-form-urlencoded", nil) == :other
    end

    test "falls back to the header when the chosen type does not parse" do
      assert BodyCheck.kind("application/xml ", "application/xml") == :xml
      assert BodyCheck.kind("nonsense", "application/x-www-form-urlencoded") == :form
      assert BodyCheck.kind("nonsense", "application/json") == :other
      assert BodyCheck.kind("nonsense", nil) == :other
    end

    test "a type that parses wins over the header" do
      assert BodyCheck.kind("application/json", "application/xml") == :other
      assert BodyCheck.kind("application/xml", "application/json") == :xml
    end
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

  test "validate/2 accepts anything for other kinds" do
    assert :ok = BodyCheck.validate(:other, %{"a" => %{"b" => nil}})
    assert :ok = BodyCheck.validate(:other, [1, 2])
  end
end
