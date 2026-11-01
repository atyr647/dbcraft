# Online-mode login primitives that exist in OTP :crypto (no NIF to write): RSA-1024 key pair, PKCS#1 v1.5 decrypt of the client's shared secret,
# and Minecraft's signed-SHA1 server hash.  (Mojang HTTPS itself not exercised: no outbound access to Mojang from this sandbox.)
import Bitwise
{pub, priv} = :crypto.generate_key(:rsa, {1024, 65537})
secret = :crypto.strong_rand_bytes(16)
enc = :crypto.public_encrypt(:rsa, secret, pub, :rsa_pkcs1_padding)
dec = :crypto.private_decrypt(:rsa, enc, priv, :rsa_pkcs1_padding)
IO.puts("RSA 1024 pkcs1 roundtrip ok=#{dec == secret} ciphertext_bytes=#{byte_size(enc)}")
t = :timer.tc(fn -> for _ <- 1..200, do: :crypto.private_decrypt(:rsa, enc, priv, :rsa_pkcs1_padding) end) |> elem(0)
IO.puts("RSA 1024 private_decrypt: #{Float.round(t / 200, 1)} us each")
# known vectors from the protocol page: sha1 of "Notch", "jeb_", "simon" as Minecraft signed hex
mc = fn s ->
  <<n::signed-160>> = :crypto.hash(:sha, s)
  if n < 0, do: "-" <> String.downcase(Integer.to_string(-n, 16)), else: String.downcase(Integer.to_string(n, 16))
end
for {s, want} <- [{"Notch", "4ed1f46bbe04bc756bcb17c0c7ce3e4632f06a48"}, {"jeb_", "-7c9d5b0044c130109a5d7b5fb5c317c02b4e28c1"}, {"simon", "88e16a1019277b15d58faf0541e11910eb756f6"}] do
  IO.puts("minecraft_hash(#{s}) = #{mc.(s)}  expected #{want}  ok=#{mc.(s) == want}")
end
{:ok, _} = Application.ensure_all_started(:inets); {:ok, _} = Application.ensure_all_started(:ssl)
IO.puts("inets+ssl available for the Mojang HTTPS call: ok")
