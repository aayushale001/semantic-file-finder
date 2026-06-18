"""A few classic sorting algorithms, kept simple for demonstration."""


def quicksort(values):
    """Return a new sorted list using the quicksort strategy."""
    if len(values) <= 1:
        return list(values)
    pivot = values[len(values) // 2]
    smaller = [v for v in values if v < pivot]
    equal = [v for v in values if v == pivot]
    larger = [v for v in values if v > pivot]
    return quicksort(smaller) + equal + quicksort(larger)


def merge_sort(values):
    """Stable, O(n log n) merge sort."""
    if len(values) <= 1:
        return list(values)
    mid = len(values) // 2
    left = merge_sort(values[:mid])
    right = merge_sort(values[mid:])
    return _merge(left, right)


def _merge(left, right):
    merged = []
    i = j = 0
    while i < len(left) and j < len(right):
        if left[i] <= right[j]:
            merged.append(left[i])
            i += 1
        else:
            merged.append(right[j])
            j += 1
    merged.extend(left[i:])
    merged.extend(right[j:])
    return merged


if __name__ == "__main__":
    sample = [5, 2, 9, 1, 5, 6]
    print("quicksort:", quicksort(sample))
    print("merge_sort:", merge_sort(sample))
