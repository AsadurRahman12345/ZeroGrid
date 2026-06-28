import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'p2p_service.dart';
import 'message_model.dart';

// ──────────────────────────────────────────────────────────────────────────────
// CHAT SCREEN
//
// Wiring overview:
//  • On mount, reads the full message history for this peer from P2PService
//    so previously exchanged messages are immediately visible.
//  • Subscribes to P2PService.messageStream (Stream<MessageModel>) and
//    calls setState() whenever a message for THIS peer arrives, causing the
//    ListView to rebuild and scroll to the bottom automatically.
//  • Sends outbound messages through P2PService.sendMessage(), which handles
//    serialisation and Nearby Connections transmission.
// ──────────────────────────────────────────────────────────────────────────────
class ChatScreen extends StatefulWidget {
  final String peerName;
  final String endpointId;

  const ChatScreen({
    super.key,
    required this.peerName,
    required this.endpointId,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _inputController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  /// Live message list for this conversation.
  /// Seeded from P2PService.messageHistory on initState, then appended to
  /// via the stream subscription for inbound messages.
  final List<MessageModel> _messages = [];

  /// Subscription to the broadcast stream. Cancelled in dispose() to avoid leaks.
  StreamSubscription<MessageModel>? _streamSub;

  /// Tracks whether a send is in-flight, so we can show a micro loading state.
  bool _isSending = false;

  @override
  void initState() {
    super.initState();

    // ── 1. Seed from history ──────────────────────────────────────────────────
    // If the user navigates back and re-opens the chat, all prior messages
    // are already in P2PService.messageHistory. Load them now.
    final service = context.read<P2PService>();
    final history = service.messageHistory[widget.endpointId] ?? [];
    _messages.addAll(history);

    // ── 2. Subscribe to live inbound stream ───────────────────────────────────
    // The stream is a broadcast (hot) stream so multiple screens can listen.
    // We filter so only messages belonging to THIS peer's conversation appear.
    _streamSub = service.messageStream.listen((MessageModel message) {
      if (!mounted) return;

      // Determine if this message belongs to our conversation:
      //   • Received messages: check that the sender's endpoint matches our peer
      //     by finding the message in the service's history for this endpointId.
      //   • Sent messages (isReceived == false): the optimistic add in _send()
      //     already inserted the bubble — skip to avoid a duplicate.
      if (message.isReceived) {
        // Guard: only accept if it's for this conversation.
        // P2PService stores received messages keyed by sender's endpointId.
        final inThisConversation =
            service.messageHistory[widget.endpointId]?.any(
                  (m) => m.id == message.id) ??
            false;

        // Also check our local list to prevent duplicate bubbles if the
        // screen was rebuilt while the message was being processed.
        final alreadyShown = _messages.any((m) => m.id == message.id);

        if (inThisConversation && !alreadyShown) {
          setState(() => _messages.add(message));
          _scrollToBottom();
        }
      }
      // Outbound messages: handled optimistically in _send(), skip here.
    });

    // Scroll to the last message after the first frame renders.
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _scrollToBottom(animated: false));
  }

  @override
  void dispose() {
    _streamSub?.cancel(); // ← Critical: prevents setState after dispose
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  // ────────────────────────────────────────────────────────────────────────────
  // SEND MESSAGE
  // ────────────────────────────────────────────────────────────────────────────
  Future<void> _send() async {
    final text = _inputController.text.trim();
    if (text.isEmpty || _isSending) return;

    final service = context.read<P2PService>();

    // Build the typed model with local sender name and outbound flag.
    final message = MessageModel(
      senderName: service.localEndpointName,
      textMessage: text,
      isReceived: false, // Outbound
    );

    // Optimistically append to UI before await returns — feels instant.
    setState(() {
      _messages.add(message);
      _isSending = true;
    });
    _inputController.clear();
    _scrollToBottom();

    try {
      // sendMessage() → toBytes() → Nearby.sendBytesPayload
      await service.sendMessage(widget.endpointId, message);
    } catch (e) {
      // Transmission failed: remove the optimistic bubble and notify user.
      if (mounted) {
        setState(() => _messages.removeLast());
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: const Color(0xFF111111),
            content: Text(
              '⚠️  Transmission failed: $e',
              style: const TextStyle(color: Color(0xFFFF5252)),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  // ────────────────────────────────────────────────────────────────────────────
  // SCROLL HELPER
  // ────────────────────────────────────────────────────────────────────────────
  void _scrollToBottom({bool animated = true}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      final target = _scrollController.position.maxScrollExtent;
      if (animated) {
        _scrollController.animateTo(
          target,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      } else {
        _scrollController.jumpTo(target);
      }
    });
  }

  // ────────────────────────────────────────────────────────────────────────────
  // BUILD
  // ────────────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(),
            Expanded(child: _buildMessageList()),
            _buildMessageInput(),
          ],
        ),
      ),
    );
  }

  // ── Header Bar ───────────────────────────────────────────────────────────────
  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 14.0),
      decoration: BoxDecoration(
        color: const Color(0xFF050505),
        border: Border(
          bottom: BorderSide(
              color: const Color(0xFF00E5FF).withOpacity(0.15)),
        ),
      ),
      child: Row(
        children: [
          // Back button
          IconButton(
            icon: const Icon(Icons.arrow_back_ios_new,
                color: Color(0xFFEEEEEE), size: 18),
            onPressed: () => Navigator.of(context).pop(),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Peer name
                Text(
                  widget.peerName,
                  style: const TextStyle(
                    color: Color(0xFFEEEEEE),
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.5,
                  ),
                ),
                const SizedBox(height: 5),
                // ⚡ DIRECTLY CONNECTED badge
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: const Color(0xFF00E5FF).withOpacity(0.05),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                        color: const Color(0xFF00E5FF).withOpacity(0.45)),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF00E5FF).withOpacity(0.1),
                        blurRadius: 6,
                        spreadRadius: 1,
                      )
                    ],
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.bolt,
                          color: Color(0xFF00E5FF), size: 11),
                      SizedBox(width: 3),
                      Text(
                        'DIRECTLY CONNECTED',
                        style: TextStyle(
                          color: Color(0xFF00E5FF),
                          fontSize: 9,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1.2,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          // Terminal icon (aesthetic motif)
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: Colors.black,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                  color: const Color(0xFF00E5FF).withOpacity(0.45),
                  width: 1),
            ),
            alignment: Alignment.center,
            child: const Text(
              '>_',
              style: TextStyle(
                color: Color(0xFF00E5FF),
                fontWeight: FontWeight.bold,
                fontSize: 13,
                fontFamily: 'monospace',
              ),
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
    );
  }

  // ── Message ListView ─────────────────────────────────────────────────────────
  Widget _buildMessageList() {
    if (_messages.isEmpty) {
      return _buildEmptyConversation();
    }
    return ListView.builder(
      controller: _scrollController,
      padding:
          const EdgeInsets.symmetric(horizontal: 16.0, vertical: 20.0),
      itemCount: _messages.length,
      itemBuilder: (context, index) =>
          _buildMessageBubble(_messages[index]),
    );
  }

  Widget _buildEmptyConversation() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('>_',
              style: TextStyle(
                  color: Color(0xFF333333),
                  fontSize: 40,
                  fontFamily: 'monospace')),
          const SizedBox(height: 12),
          Text(
            'Secure channel open',
            style: TextStyle(
                color: const Color(0xFF555555).withOpacity(0.8),
                fontSize: 14),
          ),
          const SizedBox(height: 6),
          Text(
            'Messages are end-to-end encrypted\nand never touch a server.',
            textAlign: TextAlign.center,
            style: TextStyle(
                color: const Color(0xFF444444).withOpacity(0.8),
                fontSize: 12),
          ),
        ],
      ),
    );
  }

  // ── Single Chat Bubble ────────────────────────────────────────────────────────
  Widget _buildMessageBubble(MessageModel msg) {
    final isSent = !msg.isReceived;

    return Padding(
      padding: const EdgeInsets.only(bottom: 20.0),
      child: Column(
        crossAxisAlignment:
            isSent ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          // Bubble container
          Container(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.72,
            ),
            padding: const EdgeInsets.symmetric(
                horizontal: 16.0, vertical: 12.0),
            decoration: BoxDecoration(
              color: isSent
                  ? const Color(0xFF002222)
                  : const Color(0xFF111111),
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(16),
                topRight: const Radius.circular(16),
                bottomLeft: Radius.circular(isSent ? 16 : 3),
                bottomRight: Radius.circular(isSent ? 3 : 16),
              ),
              border: Border.all(
                color: isSent
                    ? const Color(0xFF00E5FF).withOpacity(0.35)
                    : const Color(0xFF2A2A2A),
                width: 1,
              ),
              boxShadow: isSent
                  ? [
                      BoxShadow(
                        color:
                            const Color(0xFF00E5FF).withOpacity(0.04),
                        blurRadius: 8,
                        spreadRadius: 1,
                      )
                    ]
                  : null,
            ),
            child: Text(
              msg.textMessage,
              style: const TextStyle(
                color: Color(0xFFEEEEEE),
                fontSize: 15,
                height: 1.45,
              ),
            ),
          ),

          const SizedBox(height: 5),

          // Metadata row (delivery info + timestamp)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: isSent
                ? [
                    Text(
                      msg.deliveryMeta,
                      style: const TextStyle(
                        color: Color(0xFF00E5FF),
                        fontSize: 9,
                        fontFamily: 'monospace',
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      msg.formattedTime,
                      style: const TextStyle(
                          color: Color(0xFF444444), fontSize: 9),
                    ),
                  ]
                : [
                    Text(
                      msg.formattedTime,
                      style: const TextStyle(
                          color: Color(0xFF444444), fontSize: 9),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      msg.deliveryMeta,
                      style: const TextStyle(
                        color: Color(0xFF666666),
                        fontSize: 9,
                        fontFamily: 'monospace',
                        letterSpacing: 0.5,
                      ),
                    ),
                  ],
          ),
        ],
      ),
    );
  }

  // ── Message Input Bar ─────────────────────────────────────────────────────────
  Widget _buildMessageInput() {
    return Container(
      padding: const EdgeInsets.all(14.0),
      decoration: BoxDecoration(
        color: const Color(0xFF050505),
        border: Border(
          top: BorderSide(
              color: const Color(0xFF00E5FF).withOpacity(0.12)),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          // Text field
          Expanded(
            child: Container(
              constraints: const BoxConstraints(maxHeight: 120),
              padding: const EdgeInsets.symmetric(
                  horizontal: 16.0, vertical: 4.0),
              decoration: BoxDecoration(
                color: const Color(0xFF111111),
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: const Color(0xFF2A2A2A)),
              ),
              child: TextField(
                controller: _inputController,
                style: const TextStyle(
                    color: Color(0xFFEEEEEE), fontSize: 15),
                maxLines: null, // Allows multi-line growth
                keyboardType: TextInputType.multiline,
                textInputAction: TextInputAction.newline,
                onSubmitted: (_) => _send(),
                decoration: const InputDecoration(
                  hintText: 'Transmit message...',
                  hintStyle: TextStyle(color: Color(0xFF444444)),
                  border: InputBorder.none,
                  isDense: true,
                ),
              ),
            ),
          ),

          const SizedBox(width: 10),

          // Glowing send button
          GestureDetector(
            onTap: _isSending ? null : _send,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                color: _isSending
                    ? const Color(0xFF00E5FF).withOpacity(0.05)
                    : const Color(0xFF00E5FF).withOpacity(0.12),
                shape: BoxShape.circle,
                border: Border.all(
                  color: _isSending
                      ? const Color(0xFF00E5FF).withOpacity(0.3)
                      : const Color(0xFF00E5FF),
                  width: 1.5,
                ),
                boxShadow: _isSending
                    ? null
                    : [
                        BoxShadow(
                          color:
                              const Color(0xFF00E5FF).withOpacity(0.25),
                          blurRadius: 14,
                          spreadRadius: 2,
                        )
                      ],
              ),
              child: _isSending
                  ? const Padding(
                      padding: EdgeInsets.all(12.0),
                      child: CircularProgressIndicator(
                        color: Color(0xFF00E5FF),
                        strokeWidth: 1.5,
                      ),
                    )
                  : const Icon(Icons.send,
                      color: Color(0xFF00E5FF), size: 18),
            ),
          ),
        ],
      ),
    );
  }
}
