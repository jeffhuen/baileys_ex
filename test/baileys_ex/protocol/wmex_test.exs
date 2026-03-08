defmodule BaileysEx.Protocol.WMexTest do
  use ExUnit.Case, async: true

  alias BaileysEx.BinaryNode
  alias BaileysEx.Protocol.WMex

  describe "build_query/3" do
    test "builds a w:mex iq node with JSON variables as raw bytes" do
      assert %BinaryNode{
               tag: "iq",
               attrs: %{
                 "id" => "tag-1",
                 "type" => "get",
                 "to" => "s.whatsapp.net",
                 "xmlns" => "w:mex"
               },
               content: [
                 %BinaryNode{
                   tag: "query",
                   attrs: %{"query_id" => "query-123"},
                   content: {:binary, body}
                 }
               ]
             } = WMex.build_query("query-123", %{"foo" => "bar"}, "tag-1")

      assert %{"variables" => %{"foo" => "bar"}} = JSON.decode!(body)
    end
  end

  describe "extract_result/2" do
    test "extracts the requested data path from the result payload" do
      response = %BinaryNode{
        tag: "iq",
        attrs: %{"type" => "result"},
        content: [
          %BinaryNode{
            tag: "result",
            attrs: %{},
            content:
              {:binary,
               ~s({"data":{"xwa2_newsletter_create":{"id":"abc123","thread_metadata":{"name":"Test"}}}})}
          }
        ]
      }

      assert {:ok, %{"id" => "abc123", "thread_metadata" => %{"name" => "Test"}}} =
               WMex.extract_result(response, "xwa2_newsletter_create")
    end

    test "returns structured graphql errors from the result payload" do
      response = %BinaryNode{
        tag: "iq",
        attrs: %{"type" => "result"},
        content: [
          %BinaryNode{
            tag: "result",
            attrs: %{},
            content:
              {:binary,
               ~s({"errors":[{"message":"denied","extensions":{"error_code":403}}],"data":null})}
          }
        ]
      }

      assert {:error,
              {:graphql,
               %{
                 code: 403,
                 message: "GraphQL server error: denied",
                 details: %{"message" => "denied"}
               }}} =
               WMex.extract_result(response, "xwa2_newsletter_create")
    end

    test "returns an unexpected-response error when the path is missing" do
      response = %BinaryNode{
        tag: "iq",
        attrs: %{"type" => "result"},
        content: [
          %BinaryNode{
            tag: "result",
            attrs: %{},
            content: {:binary, ~s({"data":{"different_field":{"id":"abc123"}}})}
          }
        ]
      }

      assert {:error, {:unexpected_response, "newsletter create", %BinaryNode{tag: "iq"}}} =
               WMex.extract_result(response, "xwa2_newsletter_create")
    end

    test "returns a missing-result-payload error when result content is not bytes" do
      response = %BinaryNode{
        tag: "iq",
        attrs: %{"type" => "result"},
        content: [
          %BinaryNode{
            tag: "result",
            attrs: %{},
            content: [
              %BinaryNode{tag: "unexpected", attrs: %{}}
            ]
          }
        ]
      }

      assert {:error, {:missing_result_payload, %BinaryNode{tag: "iq"}}} =
               WMex.extract_result(response, "xwa2_newsletter_create")
    end
  end
end
