defmodule Redix.ProtocolTest do
  use ExUnit.Case, async: true

  import Redix.TestHelpers, only: [parse_with_continuations: 1, parse_with_continuations: 2]

  alias Redix.{Error, Protocol.ParseError}

  doctest Redix.Protocol

  describe "pack/1" do
    import Redix.Protocol, only: [pack: 1]

    test "empty array" do
      assert IO.iodata_to_binary(pack([])) == "*0\r\n"
    end

    test "regular strings" do
      assert IO.iodata_to_binary(pack(["foo", "bar"])) == "*2\r\n$3\r\nfoo\r\n$3\r\nbar\r\n"
      assert IO.iodata_to_binary(pack(["with spaces "])) == "*1\r\n$12\r\nwith spaces \r\n"
    end

    test "unicode" do
      str = "føø"
      size = byte_size(str)
      assert IO.iodata_to_binary(pack([str])) == "*1\r\n$#{size}\r\n#{str}\r\n"
    end

    test "raw bytes (non printable)" do
      assert IO.iodata_to_binary(pack([<<1, 2>>])) == <<"*1\r\n$2\r\n", 1, 2, "\r\n">>
    end
  end

  describe "parse/1" do
    import Redix.Protocol, only: [parse: 1]

    test "simple strings" do
      assert parse("+OK\r\n") == {:ok, "OK", ""}
      assert parse("+the foo is the bar\r\n") == {:ok, "the foo is the bar", ""}
      assert parse("+\r\n") == {:ok, "", ""}
      assert parse("+• º •\r\n") == {:ok, "• º •", ""}

      # Whitespace
      assert parse("+  \r\n") == {:ok, "  ", ""}
      assert parse("+\r\r\n") == {:ok, "\r", ""}
      assert parse("+\n\r\r\n") == {:ok, "\n\r", ""}
      assert parse("+  stripme!  \r\n") == {:ok, "  stripme!  ", ""}

      # Trailing stuff
      assert parse("+foo\r\nbar") == {:ok, "foo", "bar"}

      # Incomplete
      assert parse_with_continuations(["+", "OK", "\r", "\nrest"]) == {:ok, "OK", "rest"}
      assert parse_with_continuations(["+OK\r", "\nrest"]) == {:ok, "OK", "rest"}
    end

    test "errors" do
      assert parse("-ERR Error!\r\n") == {:ok, %Error{message: "ERR Error!"}, ""}
      assert parse("-\r\n") == {:ok, %Error{message: ""}, ""}
      assert parse("- Error message \r\n") == {:ok, %Error{message: " Error message "}, ""}
      assert parse("-üniçø∂e\r\n") == {:ok, %Error{message: "üniçø∂e"}, ""}

      error = %Error{message: "Error"}
      assert parse_with_continuations(["-", "Err", "or", "\r\nrest"]) == {:ok, error, "rest"}

      error = %Error{message: "Error"}
      assert parse_with_continuations(["-Error\r", "\nrest"]) == {:ok, error, "rest"}
    end

    test "integers" do
      assert parse(":42\r\n") == {:ok, 42, ""}
      assert parse(":1234567890\r\n") == {:ok, 1_234_567_890, ""}
      assert parse(":-100\r\n") == {:ok, -100, ""}
      assert parse(":0\r\nrest") == {:ok, 0, "rest"}

      assert parse_with_continuations([":", "-", "1", "\r\n"]) == {:ok, -1, ""}
      assert parse_with_continuations([":1\r", "\nrest"]) == {:ok, 1, "rest"}
      assert parse_with_continuations([":1", "3", "\r\nrest"]) == {:ok, 13, "rest"}
      assert parse_with_continuations([":-", "1", "3", "\r\nrest"]) == {:ok, -13, "rest"}
    end

    test "bulk strings" do
      assert parse("$0\r\n\r\n") == {:ok, "", ""}
      assert parse("$6\r\nfoobar\r\n") == {:ok, "foobar", ""}

      # Unicode.
      unicode_str = "ªº•¶æ"
      byte_count = byte_size(unicode_str)
      assert parse("$#{byte_count}\r\n#{unicode_str}\r\n") == {:ok, unicode_str, ""}

      # Non-printable bytes
      assert parse("$2\r\n" <> <<1, 2>> <> "\r\n") == {:ok, <<1, 2>>, ""}

      # CRLF in the bulk string.
      assert parse("$2\r\n\r\n\r\n") == {:ok, "\r\n", ""}

      # Incomplete
      assert parse_with_continuations(["$0", "\r\n\r", "\nrest"]) == {:ok, "", "rest"}
      assert parse_with_continuations(["$", "3", "\r\n", "foo\r\n"]) == {:ok, "foo", ""}

      # Null
      assert parse("$-1\r\n") == {:ok, nil, ""}
      assert parse("$-1\r\nrest") == {:ok, nil, "rest"}
      assert parse_with_continuations(["$-1", "\r", "\nrest"]) == {:ok, nil, "rest"}
      assert parse_with_continuations(["$", "-1", "\r\nrest"]) == {:ok, nil, "rest"}
      assert parse_with_continuations(["$-", "1", "\r", "\nrest"]) == {:ok, nil, "rest"}
    end

    test "arrays" do
      assert parse("*0\r\n") == {:ok, [], ""}
      assert parse("*2\r\n$3\r\nfoo\r\n$3\r\nbar\r\n") == {:ok, ["foo", "bar"], ""}

      # Mixed types
      arr = "*5\r\n:1\r\n:2\r\n:3\r\n:4\r\n$6\r\nfoobar\r\n"
      assert parse(arr) == {:ok, [1, 2, 3, 4, "foobar"], ""}

      # Says it has only 1 value, has 2
      assert parse("*1\r\n:1\r\n:2\r\n") == {:ok, [1], ":2\r\n"}

      # Null
      assert parse("*-1\r\n") == {:ok, nil, ""}
      assert parse("*-1\r\nrest") == {:ok, nil, "rest"}
      assert parse_with_continuations(["*-1", "\r", "\nrest"]) == {:ok, nil, "rest"}
      assert parse_with_continuations(["*", "-1", "\r\nrest"]) == {:ok, nil, "rest"}
      assert parse_with_continuations(["*-", "1", "\r", "\nrest"]) == {:ok, nil, "rest"}

      # Null values (of different types) in the array
      arr = "*4\r\n$3\r\nfoo\r\n$-1\r\n$3\r\nbar\r\n*-1\r\n"
      assert parse(arr) == {:ok, ["foo", nil, "bar", nil], ""}

      # Nested
      arr = "*2\r\n*3\r\n:1\r\n:2\r\n:3\r\n*2\r\n+Foo\r\n-ERR Bar\r\n"
      assert parse(arr) == {:ok, [[1, 2, 3], ["Foo", %Error{message: "ERR Bar"}]], ""}

      payload = ["*", "1\r", "\n", "+OK", "\r\nrest"]
      assert parse_with_continuations(payload) == {:ok, ["OK"], "rest"}

      payload = ["*2", "\r\n*1", "\r\n", "+", "OK\r\n", ":1", "\r\n"]
      assert parse_with_continuations(payload) == {:ok, [["OK"], 1], ""}

      payload = ["*2\r\n+OK\r\n", "+OK\r\nrest"]
      assert parse_with_continuations(payload) == {:ok, ~w(OK OK), "rest"}
    end

    test "parse/1: raising when the binary value has no type specifier" do
      msg = ~s[invalid type specifier ("f")]
      assert_raise ParseError, msg, fn -> parse("foo\r\n") end
      assert_raise ParseError, msg, fn -> parse("foo bar baz") end
    end

    test "parse/1: when the binary it's an invalid integer" do
      assert_raise ParseError, ~S(expected integer, found: "\r"), fn -> parse(":\r\n") end
      assert_raise ParseError, ~S(expected integer, found: "\r"), fn -> parse(":-\r\n") end
      assert_raise ParseError, ~S(expected CRLF, found: "a"), fn -> parse(":43a\r\n") end
      assert_raise ParseError, ~S(expected integer, found: "f"), fn -> parse(":foo\r\n") end
    end
  end

  describe "parse_multi/2" do
    import Redix.Protocol, only: [parse_multi: 2]

    test "enough elements" do
      data = "+OK\r\n+OK\r\n+OK\r\n"
      assert parse_multi(data, 3) == {:ok, ~w(OK OK OK), ""}
      assert parse_multi(data, 2) == {:ok, ~w(OK OK), "+OK\r\n"}
    end

    test "not enough data" do
      data = ["+OK\r\n+OK\r\n", "+", "OK", "\r\nrest"]
      assert parse_with_continuations(data, &parse_multi(&1, 3)) == {:ok, ~w(OK OK OK), "rest"}
    end
  end
end
