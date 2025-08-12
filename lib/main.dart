import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:social_share/social_share.dart';
import 'package:intl/intl.dart';
import 'dart:async';
import 'package:timezone/timezone.dart' as tz;
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:workmanager/workmanager.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';

@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    await Firebase.initializeApp();
    
    if (inputData == null) {
      return Future.value(false);
    }

    final String content = inputData['content'];
    final String docId = inputData['docId'];

    try {
      await SocialShare.shareOptions(content);
      await FirebaseFirestore.instance.collection('scheduled_posts').doc(docId).update({'status': 'posted'});
      return Future.value(true);
    } catch (e) {
      await FirebaseFirestore.instance.collection('scheduled_posts').doc(docId).update({'status': 'failed'});
      return Future.value(false);
    }
  });
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  tz_data.initializeTimeZones();
  await Workmanager().initialize(callbackDispatcher, isInDebugMode: false);
  runApp(const SocialSchedulerApp());
}

class SocialSchedulerApp extends StatelessWidget {
  const SocialSchedulerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      onGenerateTitle: (context) => AppLocalizations.of(context)!.appTitle,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [
        Locale('en'),
        Locale('bn'),
        Locale('es'),
      ],
      theme: ThemeData(
        primarySwatch: Colors.blue, 
        scaffoldBackgroundColor: Colors.grey[100]
      ),
      home: StreamBuilder<User?>(
        stream: FirebaseAuth.instance.authStateChanges(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Scaffold(body: Center(child: CircularProgressIndicator()));
          }
          return snapshot.hasData ? const DashboardScreen() : const LoginScreen();
        },
      ),
    );
  }
}

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _isLoading = false;
  String? _errorMessage;

  String _getErrorMessage(BuildContext context, String code) {
    final l10n = AppLocalizations.of(context)!;
    switch (code) {
      case 'invalid-email': return l10n.error_invalid_email;
      case 'user-disabled': return l10n.error_user_disabled;
      case 'user-not-found': return l10n.error_user_not_found;
      case 'wrong-password': return l10n.error_wrong_password;
      case 'email-already-in-use': return l10n.error_email_already_in_use;
      case 'weak-password': return l10n.error_weak_password;
      default: return l10n.error_unknown(code);
    }
  }

  Future<void> _authAction(Future<void> Function() action) async {
    if (!_formKey.currentState!.validate()) return;
    setState(() { _isLoading = true; _errorMessage = null; });
    try {
      await action();
    } on FirebaseAuthException catch (e) {
      if (mounted) setState(() => _errorMessage = _getErrorMessage(context, e.code));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.appTitle), centerTitle: true),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const SizedBox(height: 40),
                TextFormField(
                  controller: _emailController,
                  decoration: InputDecoration(labelText: l10n.emailLabel, prefixIcon: const Icon(Icons.email), border: const OutlineInputBorder()),
                  keyboardType: TextInputType.emailAddress,
                  validator: (v) => (v == null || v.isEmpty || !v.contains('@')) ? l10n.invalidEmailError : null,
                ),
                const SizedBox(height: 20),
                TextFormField(
                  controller: _passwordController,
                  decoration: InputDecoration(labelText: l10n.passwordLabel, prefixIcon: const Icon(Icons.lock), border: const OutlineInputBorder()),
                  obscureText: true,
                  validator: (v) => (v == null || v.length < 6) ? l10n.passwordLengthError : null,
                ),
                if (_errorMessage != null)
                  Padding(padding: const EdgeInsets.only(top: 16), child: Text(_errorMessage!, style: TextStyle(color: Colors.red[700]))),
                const SizedBox(height: 30),
                _isLoading
                    ? const CircularProgressIndicator()
                    : ElevatedButton(
                        onPressed: () => _authAction(() => FirebaseAuth.instance.signInWithEmailAndPassword(email: _emailController.text.trim(), password: _passwordController.text.trim())),
                        style: ElevatedButton.styleFrom(minimumSize: const Size(double.infinity, 50), backgroundColor: Colors.blue[700]),
                        child: Text(l10n.loginButton, style: const TextStyle(fontSize: 18, color: Colors.white)),
                      ),
                TextButton(
                  onPressed: () => _authAction(() => FirebaseAuth.instance.createUserWithEmailAndPassword(email: _emailController.text.trim(), password: _passwordController.text.trim())),
                  child: Text(l10n.createAccountButton),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});
  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  late User _user;

  @override
  void initState() {
    super.initState();
    _user = FirebaseAuth.instance.currentUser!;
  }

  Future<void> _schedulePost(String content, DateTime scheduleTime) async {
    final l10n = AppLocalizations.of(context)!;
    try {
      final docRef = await _firestore.collection('scheduled_posts').add({
        'content': content,
        'schedule_time': scheduleTime,
        'user_id': _user.uid,
        'status': 'scheduled',
      });

      final duration = scheduleTime.difference(DateTime.now());
      if (duration.isNegative) { 
        return;
      }

      await Workmanager().registerOneOffTask(
        "post_${docRef.id}",
        "socialPostTask",
        initialDelay: duration,
        inputData: {'content': content, 'docId': docRef.id},
        constraints: Constraints(networkType: NetworkType.connected),
      );
      
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.postScheduledSuccess)));
      
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.scheduleError)));
    }
  }

  Future<void> _deletePost(String docId) async {
    try {
      await Workmanager().cancelByUniqueName("post_$docId");
      await _firestore.collection('scheduled_posts').doc(docId).delete();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(AppLocalizations.of(context)!.deleteFailedError)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.dashboardTitle), centerTitle: true,
        actions: [IconButton(tooltip: l10n.logoutButton, icon: const Icon(Icons.logout), onPressed: () => FirebaseAuth.instance.signOut())],
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: _firestore.collection('scheduled_posts').where('user_id', isEqualTo: _user.uid).orderBy('schedule_time', descending: true).snapshots(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
            return Center(child: Text(l10n.noScheduledPosts));
          }
          final posts = snapshot.data!.docs;

          return ListView.builder(
            itemCount: posts.length,
            itemBuilder: (context, index) {
              final postData = posts[index].data() as Map<String, dynamic>;
              final postId = posts[index].id;
              
              final scheduleTime = (postData['schedule_time'] as Timestamp).toDate();
              
              final status = postData['status'] ?? 'unknown';
              final statusText = status == 'scheduled' ? l10n.statusScheduled : status == 'posted' ? l10n.statusPosted : l10n.statusFailed;
              final statusColor = status == 'scheduled' ? Colors.orange : status == 'posted' ? Colors.green : Colors.red;

              return Card(
                margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: ListTile(
                  contentPadding: const EdgeInsets.all(16),
                  title: Text(postData['content'] ?? ''),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 8),
                      Text(DateFormat.yMd(Localizations.localeOf(context).languageCode).add_jm().format(scheduleTime)),
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                        decoration: BoxDecoration(color: statusColor.withOpacity(0.1), borderRadius: BorderRadius.circular(20)),
                        child: Text(statusText, style: TextStyle(color: statusColor, fontWeight: FontWeight.bold)),
                      ),
                    ],
                  ),
                  trailing: IconButton(icon: const Icon(Icons.delete, color: Colors.red), onPressed: () => _deletePost(postId)),
                ),
              );
            },
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => CreatePostScreen(onSchedule: _schedulePost))),
        backgroundColor: Colors.blue[700],
        child: const Icon(Icons.add, color: Colors.white),
      ),
    );
  }
}

class CreatePostScreen extends StatefulWidget {
  final Function(String, DateTime) onSchedule;
  const CreatePostScreen({required this.onSchedule, super.key});
  @override
  State<CreatePostScreen> createState() => _CreatePostScreenState();
}

class _CreatePostScreenState extends State<CreatePostScreen> {
  final _contentController = TextEditingController();
  DateTime _scheduleTime = DateTime.now().add(const Duration(minutes: 10));
  bool _isScheduling = false;

  Future<void> _pickDateTime() async {
    final date = await showDatePicker(context: context, initialDate: _scheduleTime, firstDate: DateTime.now(), lastDate: DateTime.now().add(const Duration(days: 365)));
    if (date == null) return;
    
    final time = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(_scheduleTime));
    if (time != null) {
      setState(() => _scheduleTime = DateTime(date.year, date.month, date.day, time.hour, time.minute));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.newPostTitle), centerTitle: true),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _contentController, 
                maxLines: 5, 
                decoration: InputDecoration(hintText: l10n.postContentHint, border: const OutlineInputBorder(), filled: true, fillColor: Colors.grey[100])
              ),
              const SizedBox(height: 25),
              Text(l10n.scheduleTimeLabel, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              const SizedBox(height: 10),
              InkWell(
                onTap: _pickDateTime,
                borderRadius: BorderRadius.circular(10),
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(border: Border.all(color: Colors.grey), borderRadius: BorderRadius.circular(10)),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(DateFormat('yyyy-MM-dd hh:mm a', Localizations.localeOf(context).languageCode).format(_scheduleTime), style: const TextStyle(fontSize: 16)),
                      const Icon(Icons.calendar_today),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 30),
              _isScheduling
                ? const Center(child: CircularProgressIndicator())
                : ElevatedButton(
                    onPressed: () async {
                      if (_contentController.text.isEmpty) {
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.postContentEmptyError)));
                        return;
                      }
                      setState(() => _isScheduling = true);
                      await widget.onSchedule(_contentController.text, _scheduleTime);
                      if (mounted) Navigator.pop(context);
                    },
                    style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16), backgroundColor: Colors.blue[700]),
                    child: Text(l10n.scheduleButton, style: const TextStyle(fontSize: 18, color: Colors.white)),
                  ),
            ],
          ),
        ),
      ),
    );
  }
}
