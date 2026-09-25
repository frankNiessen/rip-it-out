"""Neighborhood attention in plain PyTorch operations.

NATTEN ships CUDA kernels and a naive CPU kernel. This module provides the four
functions that `dinat.py` takes from `natten.functional`, written with indexing
and einsum only, so that the model also runs where NATTEN has no kernel (Apple's
MPS backend) or is not installed, and runs faster on the CPU than the naive
kernel does. The operations are differentiable, so autograd provides the
backward pass.

The window and relative-position-bias index rules follow NATTEN's
csrc/include/natten/cpu/naive/natten_cpu_commons.h.
"""

import functools
import torch


def _window_start(index: int, length: int, kernel_size: int, dilation: int) -> int:
  half = kernel_size // 2
  if dilation <= 1:
    return max(index - half, 0) + (index + half >= length) * (length - index - half - 1)
  if index - half * dilation < 0:
    return index % dilation
  if index + half * dilation >= length:
    imodd = index % dilation
    a = (length // dilation) * dilation
    b = length - a
    if imodd < b:
      return length - b + imodd - 2 * half * dilation
    return a + imodd - kernel_size * dilation
  return index - half * dilation


def _bias_start(index: int, length: int, kernel_size: int, dilation: int) -> int:
  half = kernel_size // 2
  if dilation <= 1:
    return half + (index < half) * (half - index) + (index + half >= length) * (length - index - 1 - half)
  if index - half * dilation < 0:
    return kernel_size - 1 - (index // dilation)
  if index + half * dilation >= length:
    return (length - index - 1) // dilation
  return half


@functools.lru_cache(maxsize=64)
def _axis_on(device, length: int, kernel_size: int, dilation: int):
  """_axis, kept on the device, so that a call does not copy the tables again."""
  return tuple(t.to(device) for t in _axis(length, kernel_size, dilation))


@functools.lru_cache(maxsize=64)
def _axis(length: int, kernel_size: int, dilation: int):
  """For each position along one axis: the positions of its neighbors, and the
  relative-position-bias entries that pair with them. Both [length, kernel_size]."""
  steps = torch.arange(kernel_size)
  starts = torch.tensor([_window_start(i, length, kernel_size, dilation) for i in range(length)])
  biases = torch.tensor([_bias_start(i, length, kernel_size, dilation) for i in range(length)])
  return starts[:, None] + steps * dilation, biases[:, None] + steps


@functools.lru_cache(maxsize=64)
def _plane(height: int, width: int, kernel_size: int, dilation: int, device):
  rows, row_bias = _axis(height, kernel_size, dilation)
  cols, col_bias = _axis(width, kernel_size, dilation)
  # Neighbor (ki, kj) of token (i, j), as an index into the flattened H*W tokens.
  flat = (rows[:, None, :, None] * width + cols[None, :, None, :]).reshape(height, width, -1)
  shape = (height, width, kernel_size, kernel_size)
  bias_r = row_bias[:, None, :, None].expand(shape).reshape(height, width, -1)
  bias_c = col_bias[None, :, None, :].expand(shape).reshape(height, width, -1)
  return flat.to(device), bias_r.to(device), bias_c.to(device)


def natten1dqkrpb(query, key, rpb, kernel_size: int, dilation: int):
  """query, key: [B, heads, L, dim]; rpb: [heads, 2K-1]. Returns [B, heads, L, K]."""
  neighbors, bias = _axis_on(query.device, query.shape[2], kernel_size, dilation)
  scores = torch.einsum('bhld,bhlkd->bhlk', query, key[:, :, neighbors])
  return scores + rpb[:, bias]


def natten1dav(attn, value, kernel_size: int, dilation: int):
  """attn: [B, heads, L, K]; value: [B, heads, L, dim]. Returns [B, heads, L, dim]."""
  neighbors, _ = _axis_on(value.device, value.shape[2], kernel_size, dilation)
  return torch.einsum('bhlk,bhlkd->bhld', attn, value[:, :, neighbors])


def natten2dqkrpb(query, key, rpb, kernel_size: int, dilation: int):
  """query, key: [B, heads, H, W, dim]; rpb: [heads, 2K-1, 2K-1]. Returns [B, heads, H, W, K*K]."""
  b, heads, height, width, dim = query.shape
  flat, bias_r, bias_c = _plane(height, width, kernel_size, dilation, query.device)
  gathered = key.reshape(b, heads, height * width, dim)[:, :, flat]
  scores = torch.einsum('bhijd,bhijkd->bhijk', query, gathered)
  return scores + rpb[:, bias_r, bias_c]


def natten2dav(attn, value, kernel_size: int, dilation: int):
  """attn: [B, heads, H, W, K*K]; value: [B, heads, H, W, dim]. Returns [B, heads, H, W, dim]."""
  b, heads, height, width, dim = value.shape
  flat, _, _ = _plane(height, width, kernel_size, dilation, value.device)
  gathered = value.reshape(b, heads, height * width, dim)[:, :, flat]
  return torch.einsum('bhijk,bhijkd->bhijd', attn, gathered)
