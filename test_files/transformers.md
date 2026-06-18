# Notes on Transformers and Attention

The Transformer architecture replaced recurrence with **self-attention**, letting
every token attend directly to every other token in the sequence. This removes the
sequential bottleneck of RNNs and makes training far more parallelizable.

## Scaled Dot-Product Attention

Attention is computed from three projected matrices: queries (Q), keys (K), and
values (V). The output is a weighted sum of the values, where each weight comes from
the compatibility of a query with the corresponding key:

    Attention(Q, K, V) = softmax(Q Kᵀ / sqrt(d_k)) V

The division by sqrt(d_k) keeps the dot products from growing too large, which would
otherwise push the softmax into regions with vanishing gradients.

## Multi-Head Attention

Instead of a single attention function, the model runs several attention "heads" in
parallel, each with its own learned projections. Different heads can specialize: some
track syntactic relationships, others follow long-range dependencies or coreference.

## Positional Encoding

Because self-attention is permutation invariant, the model has no inherent sense of
word order. Positional encodings — either fixed sinusoids or learned vectors — are
added to the token embeddings so the network can reason about position.

## Why it matters

These ideas underpin modern large language models. Understanding attention is the key
to understanding how today's models read context, retrieve relevant information, and
generate coherent text.
