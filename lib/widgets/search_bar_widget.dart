import 'dart:async';
import 'package:flutter/material.dart';
import 'package:nari_shakti/core/services/places_service.dart';

typedef PlaceSelectedCallback =
    void Function(String placeId, String description);

class SearchBarWidget extends StatefulWidget {
  final PlaceSelectedCallback onPlaceSelected;
  const SearchBarWidget({super.key, required this.onPlaceSelected});

  @override
  State<SearchBarWidget> createState() => _SearchBarWidgetState();
}

class _SearchBarWidgetState extends State<SearchBarWidget> {
  final _controller = TextEditingController();
  final _service = PlacesService();
  Timer? _debounce;
  List<Map<String, String>> _suggestions = [];
  bool _loading = false;

  void _onChanged(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () async {
      if (v.trim().isEmpty) {
        setState(() => _suggestions = []);
        return;
      }
      setState(() => _loading = true);
      final res = await _service.getAutocomplete(v);
      if (mounted)
        setState(() {
          _suggestions = res;
          _loading = false;
        });
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: TextField(
            controller: _controller,
            onChanged: _onChanged,
            decoration: InputDecoration(
              hintText: 'Search destination',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _loading
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : null,
              filled: true,
              fillColor: Colors.white,
              contentPadding: const EdgeInsets.symmetric(vertical: 12),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ),
        if (_suggestions.isNotEmpty)
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 8)],
            ),
            constraints: const BoxConstraints(maxHeight: 240),
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: _suggestions.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (ctx, i) {
                final s = _suggestions[i];
                return ListTile(
                  title: Text(s['description'] ?? ''),
                  onTap: () {
                    widget.onPlaceSelected(
                      s['place_id'] ?? '',
                      s['description'] ?? '',
                    );
                    setState(() {
                      _suggestions = [];
                      _controller.text = s['description'] ?? '';
                    });
                  },
                );
              },
            ),
          ),
      ],
    );
  }
}
