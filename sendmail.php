<?php
use PHPMailer\PHPMailer\PHPMailer;
use PHPMailer\PHPMailer\Exception;

require 'phpmailer/src/Exception.php';
require 'phpmailer/src/PHPMailer.php';
require 'phpmailer/src/SMTP.php';

if ($_SERVER["REQUEST_METHOD"] == "POST") {
    $name = $_POST['name'];
    $email = $_POST['email'];
    $message = $_POST['message'];

    $mail = new PHPMailer(true);
    try {
        //Server settings
        $mail->isSMTP();
        $mail->Host = 'smtp.gmail.com';  // Replace with your SMTP server
        $mail->SMTPAuth = true;
        $mail->Username = 'kernelkonsulting@gmail.com';  // Your email address
        $mail->Password = '';    // Your email password
        $mail->SMTPSecure = PHPMailer::ENCRYPTION_STARTTLS;
        $mail->Port = 587;

        //Recipients
        $mail->setFrom($email, $name);
        $mail->addAddress('contact@kernelkonsulting.com');  // Add the recipient's email address

        //Content
        $mail->isHTML(false);
        $mail->Subject = "Contact Form from $name";
        $mail->Body    = "Name: $name\nEmail: $email\nMessage:\n$message";

        $mail->send();
        echo '<p>Message sent successfully!</p>';
        echo '<script>
                setTimeout(function() {
                    window.location.href = "https://kernelkonsulting.com";
                }, 3000); // 3000 milliseconds = 3 seconds
              </script>';
    } catch (Exception $e) {
        echo "Failed to send the message. Mailer Error: {$mail->ErrorInfo}";
    }
}
?>

